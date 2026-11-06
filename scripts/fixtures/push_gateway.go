// Disposable HTTP provider fixture. It does not contact APNs/FCM and never logs delivery tokens.
package main

import (
	"crypto/subtle"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"time"
)

func main() {
	secret := os.Getenv("PUSH_PROVIDER_TOKEN")
	if len(secret) < 16 {
		os.Exit(2)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })
	mux.HandleFunc("/push/send", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+secret)) != 1 {
			w.WriteHeader(403)
			return
		}
		var message struct{ IdempotencyKey, Token, Title, Body, URL string }
		if json.NewDecoder(io.LimitReader(r.Body, 16384)).Decode(&message) != nil || message.Token == "" || message.IdempotencyKey == "" {
			w.WriteHeader(400)
			return
		}
		w.WriteHeader(204)
	})
	server := &http.Server{Addr: ":8095", Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	if server.ListenAndServe() != nil {
		os.Exit(1)
	}
}
