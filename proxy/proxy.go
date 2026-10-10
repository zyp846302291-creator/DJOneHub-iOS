package main

import (
	"embed"
	"flag"
	"io/fs"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"time"
)

//go:embed web/*
var webFS embed.FS

func main() {
	listen := flag.String("listen", "0.0.0.0:7576", "listen address")
	upstream := flag.String("upstream", "http://127.0.0.1:7575", "DJOneHub backend")
	pushRelayURL := flag.String("push-relay", "", "Cloudflare Worker relay URL for VoIP push (e.g. https://djonehub-push-relay.workers.dev)")
	pushDeviceID := flag.String("push-device-id", "", "Device ID for push relay auth")
	flag.Parse()

	target, err := url.Parse(*upstream)
	if err != nil {
		log.Fatalf("invalid upstream: %v", err)
	}

	proxy := httputil.NewSingleHostReverseProxy(target)
	signaling := NewHubSignaling(*upstream)

	// Setup push relay if configured
	if *pushRelayURL != "" {
		relay := NewPushRelay(*pushRelayURL, *pushDeviceID)
		signaling.SetPushRelay(relay)
		log.Printf("Push relay enabled: %s", *pushRelayURL)
	}

	signaling.StartStatePoller(2 * time.Second)

	mux := http.NewServeMux()

	// WebSocket signaling endpoint for iOS app
	mux.HandleFunc("/ws", signaling.ServeWS)

	// Proxy all API calls to DJOneHub backend
	mux.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		proxy.ServeHTTP(w, r)
	})

	// Serve the iPhone control page
	webRoot, _ := fs.Sub(webFS, "web")
	mux.Handle("/", http.FileServer(http.FS(webRoot)))

	server := &http.Server{
		Addr:    *listen,
		Handler: mux,
	}

	log.Printf("DJOneHub Remote Control listening on %s", *listen)
	log.Printf("Proxying API to %s", *upstream)
	log.Printf("WebSocket signaling at ws://<mac-ip>:7576/ws")
	log.Printf("Open http://<mac-ip>:7576 on iPhone")

	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
