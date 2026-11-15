package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/curve25519"
)

func TestSOCKSOverAmneziaWG(t *testing.T) {
	testSOCKSOverAmneziaWG(t, false)
}

func TestSOCKSOverAmneziaWG31(t *testing.T) {
	testSOCKSOverAmneziaWG(t, true)
}

func testSOCKSOverAmneziaWG(t *testing.T, protected bool) {
	secret := func() []byte {
		b := make([]byte, 32)
		if _, err := rand.Read(b); err != nil {
			t.Fatal(err)
		}
		return b
	}
	key := func() (string, string) {
		private := secret()
		public, err := curve25519.X25519(private, curve25519.Basepoint)
		if err != nil {
			t.Fatal(err)
		}
		return base64.StdEncoding.EncodeToString(private), base64.StdEncoding.EncodeToString(public)
	}
	aPriv, aPub := key()
	bPriv, bPub := key()
	headerKey := base64.StdEncoding.EncodeToString(secret())
	presharedKey := base64.StdEncoding.EncodeToString(secret())
	portProbe, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	serverPort := portProbe.LocalAddr().(*net.UDPAddr).Port
	portProbe.Close()
	config := func(priv, pub, ip, peer string, port int) profile {
		mask := "S1 = 11\nS2 = 19\nS3 = 21\nS4 = 23\nH1 = 101-111\nH2 = 201-211\nH3 = 301-311\nH4 = 401-411\nI1 = <b 0x010203><r 5>"
		allowedIPs := peer + "/32"
		var peerOptions string
		if protected {
			mask = fmt.Sprintf("S1 = 12\nS2 = 12\nS3 = 12\nS4 = 12\nH1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\nHeaderProtectionKey = %s\nRekeyAfterTime = 100-120\nRekeyTimeout = 3-7\nRejectAfterTime = 150-180\nKeepaliveTimeout = 5-15\nMaxHandshakeAttempts = 15-20\nRandomTrailers = on\nDisableCookies = on\nContentPaddingAddition = 5-8", headerKey)
			peerOptions = fmt.Sprintf("PresharedKey = %s\n", presharedKey)
			if port == serverPort {
				peerOptions += "PersistentKeepalive = 25-35\n"
				allowedIPs = "0.0.0.0/0, ::/0"
			}
		}
		raw := fmt.Sprintf("[Interface]\nPrivateKey = %s\nAddress = %s/32\nDNS = 192.0.2.53, 192.0.2.54\nJc = 2\nJmin = 16\nJmax = 31\n%s\n[Peer]\nPublicKey = %s\nAllowedIPs = %s\nEndpoint = 127.0.0.1:%d\n%s", priv, ip, mask, pub, allowedIPs, port, peerOptions)
		p, err := readProfile(strings.NewReader(raw))
		if err != nil {
			t.Fatal(err)
		}
		if protected {
			if _, closeTunnel, err := createTunnel(p, false); err != nil {
				t.Fatal("offline profile validation:", err)
			} else {
				closeTunnel()
			}
			if port == serverPort && !strings.Contains(p.uapi, "\npersistent_keepalive_interval=25-35\n") {
				t.Fatal("keepalive range was lost")
			}
		}
		return p
	}
	const aIP = "10.45.9.1"
	const bIP = "10.45.9.2"
	serverProfile := config(bPriv, aPub, bIP, aIP, 9)
	serverProfile.uapi = fmt.Sprintf("listen_port=%d\n", serverPort) + serverProfile.uapi
	if serverBin := os.Getenv("AWG_TEST_SERVER"); serverBin != "" {
		// The other Go build reads only randomly generated fixture keys via stdin.
		cmd := exec.Command(serverBin, "-test.run=^TestEchoPeer$")
		cmd.Env = append(os.Environ(), fmt.Sprintf("AWG_TEST_PORT=%d", serverPort))
		cmd.Stdin = strings.NewReader(serverProfile.uapi)
		cmd.Stderr = os.Stderr
		ready, err := cmd.StdoutPipe()
		if err != nil {
			t.Fatal(err)
		}
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
		var marker [6]byte
		if _, err := io.ReadFull(ready, marker[:]); err != nil || string(marker[:]) != "READY\n" {
			t.Fatalf("echo peer failed: %v", err)
		}
	} else {
		defer startEchoPeer(t, serverProfile)()
	}
	client, closeClient, err := createTunnel(config(aPriv, bPub, aIP, bIP, serverPort), true)
	if err != nil {
		t.Fatal(err)
	}
	defer closeClient()
	dest := netip.MustParseAddrPort(bIP + ":9876")

	local, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer local.Close()
	go func() {
		for {
			c, err := local.Accept()
			if err != nil {
				return
			}
			go serveSOCKS(c, client)
		}
	}()
	connect := func(cmd byte, target []byte) (net.Conn, []byte) {
		c, err := net.Dial("tcp", local.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		c.SetDeadline(time.Now().Add(15 * time.Second))
		_, err = c.Write([]byte{5, 1, 0})
		if err != nil {
			t.Fatal(err)
		}
		b := make([]byte, 10)
		if _, err = io.ReadFull(c, b[:2]); err != nil || !bytes.Equal(b[:2], []byte{5, 0}) {
			t.Fatalf("SOCKS greeting: %v %v", b[:2], err)
		}
		_, err = c.Write(append([]byte{5, cmd, 0, 1}, target...))
		if err != nil {
			t.Fatal(err)
		}
		if _, err = io.ReadFull(c, b); err != nil || b[1] != 0 {
			t.Fatalf("SOCKS command %d: %v %v", cmd, b, err)
		}
		return c, b
	}
	destIP := dest.Addr().As4()
	target := binary.BigEndian.AppendUint16(destIP[:], dest.Port())
	c, _ := connect(1, target)
	if _, err = c.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	var b [4]byte
	if _, err = io.ReadFull(c, b[:]); err != nil || string(b[:]) != "ping" {
		t.Fatalf("TCP echo: %q %v", b, err)
	}
	_, resp := connect(3, []byte{0, 0, 0, 0, 0, 0})
	udp, err := net.DialUDP("udp4", nil, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: int(binary.BigEndian.Uint16(resp[8:]))})
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	udp.SetDeadline(time.Now().Add(5 * time.Second))
	want := append(append([]byte{0, 0, 0, 1}, target...), []byte("pong")...)
	if _, err = udp.Write(want); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, 100)
	n, err := udp.Read(got)
	if err != nil || !bytes.Equal(got[:n], want) {
		t.Fatalf("UDP echo: %v %v", got[:n], err)
	}
}

func TestEchoPeer(t *testing.T) {
	if os.Getenv("AWG_TEST_PORT") == "" {
		t.Skip("standalone echo peer")
	}
	uapi, err := io.ReadAll(os.Stdin)
	if err != nil {
		t.Fatal(err)
	}
	p := profile{uapi: string(uapi), endpoint: "127.0.0.1:9", mtu: 1280,
		addresses: []netip.Addr{netip.MustParseAddr("10.45.9.2")}}
	defer startEchoPeer(t, p)()
	fmt.Println("READY")
	// The parent terminates this process after the two echo requests.
	time.Sleep(20 * time.Second)
}

func startEchoPeer(t *testing.T, p profile) func() {
	server, closeServer, err := newTunnel(p, true)
	if err != nil {
		t.Fatal(err)
	}
	dest := netip.MustParseAddrPort("10.45.9.2:9876")
	echoTCP, err := server.ListenTCPAddrPort(dest)
	if err != nil {
		closeServer()
		t.Fatal(err)
	}
	echoUDP, err := server.ListenUDPAddrPort(dest)
	if err != nil {
		echoTCP.Close()
		closeServer()
		t.Fatal(err)
	}
	go func() {
		if c, err := echoTCP.Accept(); err == nil {
			defer c.Close()
			var b [4]byte
			if _, err := io.ReadFull(c, b[:]); err == nil {
				_, _ = c.Write(b[:])
			}
		}
	}()
	go func() {
		var b [10]byte
		if n, a, err := echoUDP.ReadFrom(b[:]); err == nil {
			_, _ = echoUDP.WriteTo(b[:n], a)
		}
	}()
	return func() { echoTCP.Close(); echoUDP.Close(); closeServer() }
}
