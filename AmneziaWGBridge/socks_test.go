package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"testing"
	"time"
)

// echoDial pretends to be the tunnel: every TCP destination is an echo server.
func echoDial(_ context.Context, network, _ string) (net.Conn, error) {
	if network != "tcp" {
		return nil, errors.New("only tcp")
	}
	local, remote := net.Pipe()
	go func() { defer remote.Close(); _, _ = io.Copy(remote, remote) }()
	return local, nil
}

func setTimeouts(t *testing.T, tcp, udp time.Duration) {
	oldTCP, oldUDP := tcpIdleNanos.Load(), udpIdleNanos.Load()
	tcpIdleNanos.Store(int64(tcp))
	udpIdleNanos.Store(int64(udp))
	t.Cleanup(func() { tcpIdleNanos.Store(oldTCP); udpIdleNanos.Store(oldUDP) })
}

func startServer(t *testing.T, dial dialFunc, limit int) string {
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { _ = serve(l, dial, limit); close(done) }()
	t.Cleanup(func() { l.Close(); <-done })
	return l.Addr().String()
}

// socksCommand performs the greeting and one request; it returns the reply.
func socksCommand(t *testing.T, addr string, cmd byte) (net.Conn, []byte, error) {
	t.Helper()
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	c.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := c.Write([]byte{5, 1, 0}); err != nil {
		return c, nil, err
	}
	b := make([]byte, 10)
	if _, err := io.ReadFull(c, b[:2]); err != nil {
		return c, nil, err
	}
	if _, err := c.Write([]byte{5, cmd, 0, 1, 10, 0, 0, 1, 0, 80}); err != nil {
		return c, nil, err
	}
	if _, err := io.ReadFull(c, b); err != nil {
		return c, nil, err
	}
	c.SetDeadline(time.Time{})
	return c, b, nil
}

func expectClosed(t *testing.T, c net.Conn, within time.Duration) {
	t.Helper()
	c.SetReadDeadline(time.Now().Add(within))
	var b [1]byte
	_, err := c.Read(b[:])
	if err == nil {
		t.Fatal("connection still delivers data")
	}
	if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Fatalf("connection was not closed within %v", within)
	}
}

func TestIdleTCPSessionReleasesSlot(t *testing.T) {
	setTimeouts(t, 150*time.Millisecond, time.Minute)
	addr := startServer(t, echoDial, 1)

	first, reply, err := socksCommand(t, addr, 1)
	if err != nil || reply[1] != 0 {
		t.Fatalf("first CONNECT: %v %v", reply, err)
	}
	// The only slot is taken: a second client is refused immediately.
	if _, _, err := socksCommand(t, addr, 1); err == nil {
		t.Fatal("second client was served while the slot was busy")
	}
	expectClosed(t, first, 2*time.Second)

	// After the idle session is reclaimed, new clients work again.
	deadline := time.Now().Add(2 * time.Second)
	for {
		c, reply, err := socksCommand(t, addr, 1)
		if err == nil && reply[1] == 0 {
			if _, err := c.Write([]byte("ping")); err != nil {
				t.Fatal(err)
			}
			var b [4]byte
			c.SetReadDeadline(time.Now().Add(2 * time.Second))
			if _, err := io.ReadFull(c, b[:]); err != nil || string(b[:]) != "ping" {
				t.Fatalf("echo after reclaim: %q %v", b, err)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("slot was not released: %v", err)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestActiveTCPSessionIsNotCut(t *testing.T) {
	setTimeouts(t, 150*time.Millisecond, time.Minute)
	addr := startServer(t, echoDial, 4)
	c, reply, err := socksCommand(t, addr, 1)
	if err != nil || reply[1] != 0 {
		t.Fatalf("CONNECT: %v %v", reply, err)
	}
	// Traffic for 4x the idle timeout must keep the session open.
	for i := 0; i < 12; i++ {
		msg := []byte{byte('a' + i)}
		if _, err := c.Write(msg); err != nil {
			t.Fatalf("write %d: %v", i, err)
		}
		got := make([]byte, 1)
		c.SetReadDeadline(time.Now().Add(time.Second))
		if _, err := io.ReadFull(c, got); err != nil || !bytes.Equal(got, msg) {
			t.Fatalf("echo %d: %q %v", i, got, err)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestIdleUDPAssociationIsClosed(t *testing.T) {
	setTimeouts(t, time.Minute, 150*time.Millisecond)
	addr := startServer(t, echoDial, 4)
	c, reply, err := socksCommand(t, addr, 3)
	if err != nil || reply[1] != 0 {
		t.Fatalf("UDP ASSOCIATE: %v %v", reply, err)
	}
	expectClosed(t, c, 2*time.Second)
}

func TestManyConcurrentSessions(t *testing.T) {
	setTimeouts(t, time.Minute, time.Minute)
	addr := startServer(t, echoDial, maxClients)
	// The old limit was 128; a browser in full VPN mode exceeds it easily.
	const sessions = 300
	conns := make([]net.Conn, 0, sessions)
	for i := 0; i < sessions; i++ {
		c, reply, err := socksCommand(t, addr, 1)
		if err != nil || reply[1] != 0 {
			t.Fatalf("session %d refused: %v %v", i, reply, err)
		}
		conns = append(conns, c)
	}
	var wg sync.WaitGroup
	for i, c := range conns {
		wg.Add(1)
		go func(i int, c net.Conn) {
			defer wg.Done()
			msg := []byte{byte(i)}
			c.SetDeadline(time.Now().Add(3 * time.Second))
			if _, err := c.Write(msg); err != nil {
				t.Errorf("write %d: %v", i, err)
				return
			}
			got := make([]byte, 1)
			if _, err := io.ReadFull(c, got); err != nil || got[0] != msg[0] {
				t.Errorf("echo %d: %v %v", i, got, err)
			}
		}(i, c)
	}
	wg.Wait()
}

// flakyListener fails Accept a few times before delegating to the real one.
type flakyListener struct {
	net.Listener
	mu       sync.Mutex
	failures int
}

func (f *flakyListener) Accept() (net.Conn, error) {
	f.mu.Lock()
	if f.failures > 0 {
		f.failures--
		f.mu.Unlock()
		return nil, errors.New("accept: too many open files")
	}
	f.mu.Unlock()
	return f.Listener.Accept()
}

func TestServeSurvivesAcceptErrors(t *testing.T) {
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	fl := &flakyListener{Listener: l, failures: 3}
	done := make(chan error, 1)
	go func() { done <- serve(fl, echoDial, 4) }()
	c, reply, err := socksCommand(t, l.Addr().String(), 1)
	if err != nil || reply[1] != 0 {
		t.Fatalf("CONNECT after Accept errors: %v %v", reply, err)
	}
	c.Close()
	l.Close()
	select {
	case err := <-done:
		if !errors.Is(err, net.ErrClosed) {
			t.Fatalf("serve returned %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("serve did not stop after the listener was closed")
	}
}
