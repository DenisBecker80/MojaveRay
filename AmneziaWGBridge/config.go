package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"time"
)

const maxConfig = 65536

var interfaceRangeKeys = map[string]string{
	"contentpaddingaddition": "content_padding_addition",
	"rekeyaftertime":         "rekey_after_time",
	"rekeytimeout":           "rekey_timeout",
	"rejectaftertime":        "reject_after_time",
	"keepalivetimeout":       "keepalive_timeout",
	"maxhandshakeattempts":   "max_handshake_attempts",
}

type profile struct {
	addresses, dns []netip.Addr
	routes         []netip.Prefix
	mtu            int
	uapi, endpoint string
}

func readProfile(r io.Reader) (profile, error) {
	p := profile{mtu: 1280}
	raw, err := io.ReadAll(io.LimitReader(r, maxConfig+1))
	if err != nil || len(raw) > maxConfig {
		return p, errors.New("не удалось прочитать профиль AmneziaWG (максимум 64 КБ)")
	}
	values := map[string]map[string]string{}
	scan := bufio.NewScanner(strings.NewReader(strings.TrimPrefix(string(raw), "\uFEFF")))
	var section string
	for n := 1; scan.Scan(); n++ {
		line := strings.TrimSpace(strings.SplitN(scan.Text(), "#", 2)[0])
		if line == "" || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			section = strings.ToLower(line)
			if (section != "[interface]" && section != "[peer]") || values[section] != nil {
				return p, fmt.Errorf("строка %d: ожидаются одна секция Interface и одна секция Peer", n)
			}
			values[section] = map[string]string{}
			continue
		}
		fields := strings.SplitN(line, "=", 2)
		if len(fields) != 2 || values[section] == nil {
			return p, fmt.Errorf("строка %d: неверный формат профиля", n)
		}
		key := strings.ToLower(strings.TrimSpace(fields[0]))
		if _, exists := values[section][key]; exists {
			return p, fmt.Errorf("строка %d: повторяющееся поле", n)
		}
		value := strings.TrimSpace(fields[1])
		if strings.IndexFunc(value, func(r rune) bool { return r < 32 || r == 127 }) >= 0 {
			return p, fmt.Errorf("строка %d: управляющий символ", n)
		}
		values[section][key] = value
	}
	if scan.Err() != nil {
		return p, errors.New("строка профиля слишком длинная")
	}
	a, b := values["[interface]"], values["[peer]"]
	privateKey, ok := hexKey(a["privatekey"])
	if !ok {
		return p, errors.New("неверный PrivateKey")
	}
	publicKey, ok := hexKey(b["publickey"])
	if !ok {
		return p, errors.New("неверный PublicKey")
	}
	var u strings.Builder
	fmt.Fprintf(&u, "private_key=%s\n", privateKey)
	for _, token := range list(a["address"]) {
		addr, err := netip.ParsePrefix(token)
		if err != nil {
			return p, errors.New("неверный Address")
		}
		p.addresses = append(p.addresses, addr.Addr())
	}
	if len(p.addresses) == 0 {
		return p, errors.New("нет Address")
	}
	for _, token := range list(a["dns"]) {
		addr, err := netip.ParseAddr(token)
		if err != nil {
			return p, errors.New("DNS должен быть указан IP-адресом")
		}
		p.dns = append(p.dns, addr)
	}
	if len(p.dns) == 0 {
		p.dns = []netip.Addr{netip.MustParseAddr("1.1.1.1")}
	}
	if val := a["mtu"]; val != "" {
		p.mtu, err = strconv.Atoi(val)
		if err != nil || p.mtu < 576 || p.mtu > 9000 {
			return p, errors.New("неверный MTU")
		}
	}
	for k, v := range a {
		if uapiKey, ok := interfaceRangeKeys[k]; ok {
			value, valid := awgRange(v)
			if !valid {
				return p, fmt.Errorf("неверное значение параметра %s", uapiKey)
			}
			fmt.Fprintf(&u, "%s=%s\n", uapiKey, value)
			continue
		}
		switch k {
		case "address", "dns", "privatekey", "mtu", "table", "listenport":
			// Local client uses an ephemeral UDP port and does not change OS routes.
		case "jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5":
			if v != "" {
				fmt.Fprintf(&u, "%s=%s\n", k, v)
			}
		case "headerprotectionkey":
			if v != "" {
				key, ok := hexKey(v)
				if !ok {
					return p, errors.New("неверный HeaderProtectionKey")
				}
				fmt.Fprintf(&u, "header_protection_key=%s\n", key)
			}
		case "randomtrailers", "disablecookies":
			uapiKey := "random_trailers"
			if k == "disablecookies" {
				uapiKey = "disable_cookies"
			}
			switch strings.ToLower(v) {
			case "on", "true", "1":
				fmt.Fprintf(&u, "%s=true\n", uapiKey)
			case "off", "false", "0", "":
				fmt.Fprintf(&u, "%s=false\n", uapiKey)
			default:
				return p, fmt.Errorf("неверное значение параметра %s: ожидается on или off", uapiKey)
			}
		default:
			return p, errors.New("в секции Interface есть неподдерживаемое поле; экспортируйте оригинальный профиль AmneziaWG")
		}
	}
	fmt.Fprintf(&u, "public_key=%s\n", publicKey)
	for k, v := range b {
		switch k {
		case "publickey", "allowedips", "endpoint":
		case "presharedkey":
			key, ok := hexKey(v)
			if !ok {
				return p, errors.New("неверный PresharedKey")
			}
			fmt.Fprintf(&u, "preshared_key=%s\n", key)
		case "persistentkeepalive":
			sec, ok := awgRange(v)
			if !ok {
				return p, errors.New("неверный PersistentKeepalive")
			}
			fmt.Fprintf(&u, "persistent_keepalive_interval=%s\n", sec)
		default:
			return p, errors.New("в секции Peer есть неподдерживаемое поле")
		}
	}
	host, port, err := net.SplitHostPort(b["endpoint"])
	pn, pe := strconv.ParseUint(port, 10, 16)
	if err != nil || pe != nil || pn == 0 || host == "" || strings.ContainsAny(host, " \t/") {
		return p, errors.New("неверный Endpoint")
	}
	p.endpoint = b["endpoint"]
	for _, v := range list(b["allowedips"]) {
		route, err := netip.ParsePrefix(v)
		if err != nil {
			return p, errors.New("неверный AllowedIPs")
		}
		p.routes = append(p.routes, route.Masked())
		fmt.Fprintf(&u, "allowed_ip=%s\n", route.Masked())
	}
	if len(p.routes) == 0 {
		return p, errors.New("нет AllowedIPs")
	}
	p.uapi = u.String()
	return p, nil
}

func list(s string) []string {
	var out []string
	for _, v := range strings.Split(s, ",") {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	return out
}
func hexKey(s string) (string, bool) {
	b, err := base64.StdEncoding.Strict().DecodeString(s)
	return hex.EncodeToString(b), err == nil && len(b) == 32
}

// AWG 3.1 picks values from these ranges itself; never collapse them to a fixed value.
func awgRange(value string) (string, bool) {
	switch strings.ToLower(value) {
	case "", "off", "(off)":
		return "0", true
	}
	left, right, rangeSpecified := strings.Cut(value, "-")
	lo, err := strconv.ParseUint(strings.TrimSpace(left), 10, 32)
	if err != nil {
		return "", false
	}
	if !rangeSpecified {
		return strconv.FormatUint(lo, 10), true
	}
	hi, err := strconv.ParseUint(strings.TrimSpace(right), 10, 32)
	if err != nil || hi < lo || hi-lo == (1<<32)-1 {
		return "", false
	}
	return fmt.Sprintf("%d-%d", lo, hi), true
}

// The bootstrap lookup is for the VPN server only. The SOCKS destination uses
// the DNS resolver inside the encrypted netstack.
func resolveEndpoint(endpoint string) (string, error) {
	host, port, err := net.SplitHostPort(endpoint)
	if err != nil {
		return "", errors.New("неверный Endpoint")
	}
	if ip, err := netip.ParseAddr(host); err == nil {
		return net.JoinHostPort(ip.String(), port), nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	ips, err := net.DefaultResolver.LookupIPAddr(ctx, host)
	if err != nil || len(ips) == 0 {
		return "", errors.New("не удалось разрешить имя сервера AmneziaWG")
	}
	for _, ip := range ips {
		if ip.IP.To4() != nil {
			return net.JoinHostPort(ip.IP.To4().String(), port), nil
		}
	}
	return net.JoinHostPort(ips[0].String(), port), nil
}
