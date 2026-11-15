package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// Without these limits a session whose peer vanished (sleep, Wi-Fi change,
// tunnel stall) keeps its slot forever, and the bridge eventually refuses all
// new connections. Atomic so tests can shorten them while sessions run.
var tcpIdleNanos, udpIdleNanos atomic.Int64

func init() {
	tcpIdleNanos.Store(int64(3 * time.Minute))
	udpIdleNanos.Store(int64(2 * time.Minute))
}

func tcpIdleTimeout() time.Duration { return time.Duration(tcpIdleNanos.Load()) }
func udpIdleTimeout() time.Duration { return time.Duration(udpIdleNanos.Load()) }

// activity records the last moment any byte moved in either direction.
type activity struct{ last atomic.Int64 }

func newActivity() *activity {
	a := &activity{}
	a.touch()
	return a
}

func (a *activity) touch() { a.last.Store(time.Now().UnixNano()) }

func (a *activity) idle() time.Duration {
	return time.Duration(time.Now().UnixNano() - a.last.Load())
}

// watchIdle closes every closer once the session has been idle for timeout.
// The returned function stops the watcher; it is safe to call more than once.
func watchIdle(a *activity, timeout time.Duration, closers ...io.Closer) func() {
	done := make(chan struct{})
	var once sync.Once
	tick := timeout / 4
	if tick < 10*time.Millisecond {
		tick = 10 * time.Millisecond
	}
	go func() {
		t := time.NewTicker(tick)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				if a.idle() >= timeout {
					for _, c := range closers {
						_ = c.Close()
					}
					return
				}
			}
		}
	}()
	return func() { once.Do(func() { close(done) }) }
}

// copyActive is io.Copy that marks the session active on every chunk.
func copyActive(dst io.Writer, src io.Reader, a *activity) {
	buf := make([]byte, 16*1024)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			a.touch()
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

func target(r io.Reader, atyp byte) (string, error) {
	n := 0
	switch atyp {
	case 1:
		n = 4
	case 4:
		n = 16
	case 3:
		var b [1]byte
		if _, e := io.ReadFull(r, b[:]); e != nil {
			return "", e
		}
		n = int(b[0])
		if n == 0 {
			return "", errors.New("empty address")
		}
	default:
		return "", errors.New("unsupported address")
	}
	b := make([]byte, n+2)
	if _, e := io.ReadFull(r, b); e != nil {
		return "", e
	}
	host := string(b[:n])
	if atyp != 3 {
		host = net.IP(b[:n]).String()
	}
	return net.JoinHostPort(host, strconv.Itoa(int(binary.BigEndian.Uint16(b[n:])))), nil
}
func reply(c net.Conn, status byte, port int) error {
	_, e := c.Write([]byte{5, status, 0, 1, 127, 0, 0, 1, byte(port >> 8), byte(port)})
	return e
}
func serveSOCKS(c net.Conn, dial dialFunc) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(8 * time.Second))
	r := bufio.NewReader(c)
	v, e := r.ReadByte()
	if e != nil || v != 5 {
		return
	}
	n, e := r.ReadByte()
	if e != nil || n == 0 {
		return
	}
	methods := make([]byte, int(n))
	if _, e = io.ReadFull(r, methods); e != nil {
		return
	}
	if bytes.IndexByte(methods, 0) < 0 {
		c.Write([]byte{5, 255})
		return
	}
	if _, e = c.Write([]byte{5, 0}); e != nil {
		return
	}
	var h [4]byte
	if _, e = io.ReadFull(r, h[:]); e != nil || h[0] != 5 || h[2] != 0 {
		return
	}
	dest, e := target(r, h[3])
	if e != nil {
		reply(c, 8, 0)
		return
	}
	switch h[1] {
	case 1:
		c.SetDeadline(time.Now().Add(15 * time.Second))
		ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
		out, e := dial(ctx, "tcp", dest)
		cancel()
		if e != nil {
			reply(c, 4, 0)
			return
		}
		defer out.Close()
		if reply(c, 0, 0) != nil {
			return
		}
		c.SetDeadline(time.Time{})
		act := newActivity()
		stopIdle := watchIdle(act, tcpIdleTimeout(), c, out)
		defer stopIdle()
		done := make(chan struct{})
		go func() { copyActive(out, r, act); closeWrite(out); close(done) }()
		copyActive(c, out, act)
		closeWrite(c)
		// Bound half-closed sessions so a broken peer cannot retain a slot forever.
		select {
		case <-done:
		case <-time.After(15 * time.Second):
		}
	case 3:
		udpRelay(c, r, dial)
	default:
		reply(c, 7, 0)
	}
}
func closeWrite(c net.Conn) {
	if w, ok := c.(interface{ CloseWrite() error }); ok {
		_ = w.CloseWrite()
	}
}
func udpRelay(c net.Conn, r *bufio.Reader, dial dialFunc) {
	relay, e := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if e != nil {
		reply(c, 1, 0)
		return
	}
	defer relay.Close()
	if reply(c, 0, relay.LocalAddr().(*net.UDPAddr).Port) != nil {
		return
	}
	c.SetDeadline(time.Time{})
	act := newActivity()
	// Closing the control connection ends the association for the client too.
	stopIdle := watchIdle(act, udpIdleTimeout(), relay, c)
	defer stopIdle()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { io.Copy(io.Discard, r); cancel(); relay.Close() }()
	var mu sync.Mutex
	flows := map[string]net.Conn{}
	defer func() {
		mu.Lock()
		defer mu.Unlock()
		for _, f := range flows {
			f.Close()
		}
	}()
	packet := make([]byte, 65535)
	var client *net.UDPAddr
	for {
		n, from, e := relay.ReadFromUDP(packet)
		if e != nil {
			return
		}
		if client != nil && from.String() != client.String() {
			continue
		}
		if n < 4 || packet[0] != 0 || packet[1] != 0 || packet[2] != 0 {
			continue
		}
		p := bytes.NewReader(packet[4:n])
		dest, e := target(p, packet[3])
		if e != nil || p.Len() == 0 {
			continue
		}
		if client == nil {
			client = from
		}
		act.touch()
		hdr := append([]byte(nil), packet[:n-p.Len()]...)
		payload := packet[n-p.Len() : n]
		mu.Lock()
		out := flows[dest]
		count := len(flows)
		mu.Unlock()
		if out == nil {
			if count >= 64 {
				continue
			}
			dctx, stop := context.WithTimeout(ctx, 4*time.Second)
			out, e = dial(dctx, "udp", dest)
			stop()
			if e != nil {
				continue
			}
			mu.Lock()
			flows[dest] = out
			mu.Unlock()
			go func(key string, remote net.Conn, header []byte, receiver *net.UDPAddr) {
				defer func() { mu.Lock(); delete(flows, key); mu.Unlock(); remote.Close() }()
				b := make([]byte, 65535)
				copy(b, header)
				for {
					remote.SetReadDeadline(time.Now().Add(30 * time.Second))
					n, e := remote.Read(b[len(header):])
					if e != nil {
						return
					}
					act.touch()
					if _, e = relay.WriteToUDP(b[:len(header)+n], receiver); e != nil {
						return
					}
				}
			}(dest, out, hdr, client)
		}
		out.SetWriteDeadline(time.Now().Add(time.Second))
		out.Write(payload)
	}
}
