//go:build !awg2

package main

import (
	"errors"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun/netstack"
)

func createTunnel(p profile, up bool) (dialFunc, func(), error) {
	stack, closeTunnel, err := newTunnel(p, up)
	if err != nil {
		return nil, nil, err
	}
	return stack.DialContext, closeTunnel, nil
}

// The app does not manage host routes. Hide the concrete bind type so the
// engine also skips Linux netlink route monitoring in userspace tests.
type userspaceBind struct{ conn.Bind }

func newTunnel(p profile, up bool) (*netstack.Net, func(), error) {
	var endpoint string
	if up {
		var err error
		endpoint, err = resolveEndpoint(p.endpoint)
		if err != nil {
			return nil, nil, err
		}
	}
	tun, stack, err := netstack.CreateNetTUN(p.addresses, p.dns, p.mtu)
	if err != nil {
		return nil, nil, errors.New("не удалось запустить сетевой стек AmneziaWG")
	}
	d := device.NewDevice(tun, userspaceBind{conn.NewDefaultBind()}, device.NewLogger(device.LogLevelSilent, ""))
	config := p.uapi
	// Validation must not resolve a real endpoint or open a tunnel.
	if up {
		config += "endpoint=" + endpoint + "\n"
	}
	if err = d.IpcSet(config); err != nil {
		d.Close()
		return nil, nil, errors.New("движок AmneziaWG отклонил профиль; проверьте Endpoint и параметры обфускации")
	}
	if up {
		if err = d.Up(); err != nil {
			d.Close()
			return nil, nil, errors.New("не удалось открыть UDP-сокет AmneziaWG")
		}
	}
	return stack, d.Close, nil
}
