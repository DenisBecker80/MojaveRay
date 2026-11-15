package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/tun/netstack"
	"golang.org/x/crypto/curve25519"
)

// TestMemoryUnderStalledDownloads models the worst case of full VPN mode:
// many streams where the server keeps sending and the app does not read
// (paused videos, background tabs). Every byte the stack is willing to buffer
// stays in memory, so this measures the real per-session cost.
//
// Opt-in, takes about half a minute:
//
//	AWG_MEMTEST=1 go test -run TestMemoryUnderStalledDownloads -v -modfile=mojave.mod .
func TestMemoryUnderStalledDownloads(t *testing.T) {
	if os.Getenv("AWG_MEMTEST") == "" {
		t.Skip("set AWG_MEMTEST=1")
	}
	sessions := 300
	client, server, cleanup := pairedTunnels(t)
	defer cleanup()

	dest := netip.MustParseAddrPort("10.45.9.2:9877")
	l, err := server.ListenTCPAddrPort(dest)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	go func() {
		chunk := make([]byte, 32*1024)
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				for {
					c.SetWriteDeadline(time.Now().Add(20 * time.Second))
					if _, err := c.Write(chunk); err != nil {
						return
					}
				}
			}()
		}
	}()

	addr := startServer(t, client, maxClients)
	destIP := dest.Addr().As4()
	target := binary.BigEndian.AppendUint16(destIP[:], dest.Port())

	before := heapMB()
	conns := make([]net.Conn, 0, sessions)
	for i := 0; i < sessions; i++ {
		c, err := net.Dial("tcp", addr)
		if err != nil {
			t.Fatal(err)
		}
		conns = append(conns, c)
		c.SetDeadline(time.Now().Add(10 * time.Second))
		c.Write([]byte{5, 1, 0})
		var b [10]byte
		if _, err := io.ReadFull(c, b[:2]); err != nil {
			t.Fatal(err)
		}
		c.Write(append([]byte{5, 1, 0, 1}, target...))
		if _, err := io.ReadFull(c, b[:]); err != nil || b[1] != 0 {
			t.Fatalf("CONNECT %d: %v %v", i, b, err)
		}
		// Read a little to prove the stream works, then stall.
		if _, err := io.ReadFull(c, make([]byte, 1024)); err != nil {
			t.Fatalf("first bytes %d: %v", i, err)
		}
	}
	// Let every buffer on the path fill up.
	var peak float64
	for i := 0; i < 10; i++ {
		time.Sleep(time.Second)
		if m := heapMB(); m > peak {
			peak = m
		}
	}
	perSession := (peak - before) / float64(sessions)
	t.Logf("%d stalled sessions: heap %.0f MB → %.0f MB, %.2f MB per session (both peers in one process)",
		sessions, before, peak, perSession)
	t.Logf("extrapolated to maxClients=%d: %.0f MB", maxClients, perSession*float64(maxClients))
	for _, c := range conns {
		c.Close()
	}
	// Two peers live in this process, so the bridge alone is below this.
	if worst := perSession * float64(maxClients); worst > 1024 {
		t.Fatalf("worst case %.0f MB for %d stalled sessions exceeds 1 GB", worst, maxClients)
	}
	// Closed sessions must give their buffers back (no leak).
	deadline := time.Now().Add(15 * time.Second)
	for {
		after := heapMB()
		if after <= before+64 {
			t.Logf("after closing: heap %.0f MB", after)
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("memory not released after sessions closed: %.0f MB, was %.0f MB", after, before)
		}
		time.Sleep(500 * time.Millisecond)
	}
}

func heapMB() float64 {
	runtime.GC()
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	return float64(m.HeapInuse+m.StackInuse) / (1 << 20)
}

// pairedTunnels connects two in-process AmneziaWG peers over loopback UDP.
func pairedTunnels(t *testing.T) (dialFunc, *netstack.Net, func()) {
	key := func() (string, string) {
		private := make([]byte, 32)
		if _, err := rand.Read(private); err != nil {
			t.Fatal(err)
		}
		public, err := curve25519.X25519(private, curve25519.Basepoint)
		if err != nil {
			t.Fatal(err)
		}
		return base64.StdEncoding.EncodeToString(private), base64.StdEncoding.EncodeToString(public)
	}
	aPriv, aPub := key()
	bPriv, bPub := key()
	probe, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	serverPort := probe.LocalAddr().(*net.UDPAddr).Port
	probe.Close()
	config := func(priv, pub, ip, peer string, port int) profile {
		raw := fmt.Sprintf("[Interface]\nPrivateKey = %s\nAddress = %s/32\nJc = 2\nJmin = 16\nJmax = 31\nS1 = 11\nS2 = 19\nH1 = 101-111\nH2 = 201-211\nH3 = 301-311\nH4 = 401-411\n\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\nEndpoint = 127.0.0.1:%d\n",
			priv, ip, pub, peer, port)
		p, err := readProfile(strings.NewReader(raw))
		if err != nil {
			t.Fatal(err)
		}
		return p
	}
	serverProfile := config(bPriv, aPub, "10.45.9.2", "10.45.9.1", 9)
	serverProfile.uapi = fmt.Sprintf("listen_port=%d\n", serverPort) + serverProfile.uapi
	server, closeServer, err := newTunnel(serverProfile, true)
	if err != nil {
		t.Fatal(err)
	}
	client, closeClient, err := createTunnel(config(aPriv, bPub, "10.45.9.1", "10.45.9.2", serverPort), true)
	if err != nil {
		closeServer()
		t.Fatal(err)
	}
	return client, server, func() { closeClient(); closeServer() }
}
