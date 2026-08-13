// Copyright 2026 Ratio1
// Licensed under the Apache License, Version 2.0. See LICENSE.

package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
)

func main() {
	listenAddress := flag.String("listen", "", "TCP address to listen on")
	targetAddress := flag.String("target", "", "TCP address to proxy to")
	connectionLog := flag.String("connection-log", "", "optional file receiving one line per accepted connection")
	flag.Parse()
	if *listenAddress == "" || *targetAddress == "" {
		log.Fatal("both --listen and --target are required")
	}

	listener, err := net.Listen("tcp", *listenAddress)
	if err != nil {
		log.Fatal(err)
	}
	defer listener.Close()

	for {
		client, err := listener.Accept()
		if err != nil {
			log.Fatal(err)
		}
		if *connectionLog != "" {
			file, err := os.OpenFile(*connectionLog, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
			if err != nil {
				log.Fatal(err)
			}
			if _, err := fmt.Fprintln(file, "connection"); err != nil {
				_ = file.Close()
				log.Fatal(err)
			}
			if err := file.Close(); err != nil {
				log.Fatal(err)
			}
		}
		go proxy(client, *targetAddress)
	}
}

func proxy(client net.Conn, targetAddress string) {
	defer client.Close()
	target, err := net.Dial("tcp", targetAddress)
	if err != nil {
		return
	}
	defer target.Close()

	done := make(chan struct{}, 2)
	copyStream := func(destination, source net.Conn) {
		_, _ = io.Copy(destination, source)
		if tcp, ok := destination.(*net.TCPConn); ok {
			_ = tcp.CloseWrite()
		}
		done <- struct{}{}
	}
	go copyStream(target, client)
	go copyStream(client, target)
	<-done
}
