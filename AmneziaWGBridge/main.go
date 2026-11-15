package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	validate := flag.Bool("validate", false, "validate profile on stdin")
	port := flag.Int("port", 10808, "local SOCKS5 port")
	flag.Parse()
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
	limit := make(chan struct{}, 128)
	for {
		c, err := l.Accept()
		if err != nil {
			return
		}
		select {
		case limit <- struct{}{}:
			go func() { defer func() { <-limit }(); serveSOCKS(c, dial) }()
		default:
			c.Close()
		}
	}
}

type dialFunc func(context.Context, string, string) (net.Conn, error)

func fatal(message string) { fmt.Fprintln(os.Stderr, message); os.Exit(1) }
