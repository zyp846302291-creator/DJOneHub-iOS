package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"sync"
	"time"
)

// PushRelay handles sending VoIP push notifications via Cloudflare Worker
type PushRelay struct {
	relayURL    string
	deviceID    string
	httpClient  *http.Client
	lastCallID  string // dedup: avoid sending push for same call
	mu          sync.Mutex
}

func NewPushRelay(relayURL, deviceID string) *PushRelay {
	return &PushRelay{
		relayURL:   relayURL,
		deviceID:   deviceID,
		httpClient: &http.Client{Timeout: 5 * time.Second},
	}
}

// SendCallPush sends a VoIP push to wake up iPhone for incoming call
func (pr *PushRelay) SendCallPush(callerNumber, callUUID string) error {
	pr.mu.Lock()
	// Dedup: don't send push for same call twice
	if pr.lastCallID == callUUID {
		pr.mu.Unlock()
		return nil
	}
	pr.lastCallID = callUUID
	pr.mu.Unlock()

	if pr.relayURL == "" {
		return fmt.Errorf("relay URL not configured")
	}

	url := fmt.Sprintf("%s/v1/events/call", pr.relayURL)
	body := map[string]string{
		"caller":    callerNumber,
		"call_uuid": callUUID,
	}
	data, _ := json.Marshal(body)

	req, err := http.NewRequest("POST", url, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	// Auth: device_id + device_secret (sent as query params or headers)
	req.Header.Set("X-Device-ID", pr.deviceID)

	resp, err := pr.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("relay request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("relay returned %d: %s", resp.StatusCode, string(respBody))
	}

	log.Printf("[Push] VoIP push sent for call from %s (uuid=%s)", callerNumber, callUUID)
	return nil
}

// ResetDedup clears the last call ID (call when call ends)
func (pr *PushRelay) ResetDedup() {
	pr.mu.Lock()
	pr.lastCallID = ""
	pr.mu.Unlock()
}