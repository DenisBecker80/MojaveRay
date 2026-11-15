package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"runtime/debug"
	"syscall"
	"time"
)

func main() {
	validate := flag.Bool("validate", false, "validate profile on stdin")
	port := flag.Int("port", 10808, "local SOCKS5 port")
	flag.Parse()
	debug.SetMemoryLimit(memoryLimit)
	p, e := readProfile(os.Stdin)
	if e != nil {
		fatal(e.Error())
	}
	if *validate {
		if _, closeTunnel, err := createTunnel(p, false); err != nil {
			fatal(err.Error())
		} else {
			closeTunnel()
		}
		return
	}
	dial, closeTunnel, err := createTunnel(p, true)
	if err != nil {
		fatal(err.Error())
	}
	defer closeTunnel()
	l, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", *port))
	if err != nil {
		fatal("порт SOCKS5 занят или недоступен")
	}
	defer l.Close()
	go func() {
		// The parent app owns this process. Exit if it is killed or crashes.
		parent := os.Getppid()
		if parent <= 1 {
			return
		}
		for range time.NewTicker(time.Second).C {
			if os.Getppid() != parent {
				_ = l.Close()
				return
			}
		}
	}()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() { <-sig; _ = l.Close() }()
	fmt.Println("AWG_SOCKS_READY")
	_ = serve(l, dial, maxClients)
}

// In full VPN mode every TCP connection and every UDP flow of the whole Mac
// passes through this listener. Each session may hold up to ~1 MB of buffers
// (see memory_test.go), so the limit bounds memory as well; idle sessions are
// reclaimed by the timeouts in socks.go, which keeps 512 well above what a
// browser needs at once.
const maxClients = 512

// Soft limit: makes the GC return memory to macOS early instead of letting
// the heap grow to twice the live data.
const memoryLimit = 384 << 20

// serve returns only when the listener is closed. Transient Accept errors
// (EMFILE, ECONNABORTED) must not stop the bridge: the app would keep its
// routes pointing at a dead proxy.
func serve(l net.Listener, dial dialFunc, limit int) error {
	slots := make(chan struct{}, limit)
	var backoff time.Duration
	for {
		c, err := l.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return err
			}
			if backoff == 0 {
				backoff = 5 * time.Millisecond
			} else if backoff < time.Second {
				backoff *= 2
			}
			time.Sleep(backoff)
			continue
		}
		backoff = 0
		select {
		case slots <- struct{}{}:
			go func() { defer func() { <-slots }(); serveSOCKS(c, dial) }()
		default:
			c.Close()
		}
	}
}

type dialFunc func(context.Context, string, string) (net.Conn, error)

func fatal(message string) { fmt.Fprintln(os.Stderr, message); os.Exit(1) }
