package main

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"sync"
	"time"
)

// PushRelay handles sending VoIP push notifications via Cloudflare Worker.
//
// 协议对齐 push-relay-worker /v1/events/call（receiveCall）：
//   - body 携带 device_id + device_secret（与 iPhone App /v1/devices/register
//     使用的同一对凭证，Worker 端按 sha256(secret) 比对）
//   - event 必须为 "incoming_call"
//   - call_id 非空；call_uuid 必须是标准 UUID 格式
//   - expires_at 为 ISO 时间，窗口 (now-5s, now+120s]
type PushRelay struct {
	relayURL   string
	httpClient *http.Client
	lastCallID string // dedup: avoid sending push for same call
	mu         sync.Mutex

	// iPhone 经 WebSocket 上报的设备凭证（push_credentials 消息），
	// 或由命令行参数注入。二者取后设置者。
	credentials pushCredentials
}

type pushCredentials struct {
	DeviceID     string `json:"device_id"`
	DeviceSecret string `json:"device_secret"`
}

func NewPushRelay(relayURL, deviceID, deviceSecret string) *PushRelay {
	return &PushRelay{
		relayURL:   relayURL,
		httpClient: &http.Client{Timeout: 5 * time.Second},
		credentials: pushCredentials{
			DeviceID:     deviceID,
			DeviceSecret: deviceSecret,
		},
	}
}

// UpdateCredentials 更新 iPhone 上报的设备凭证。
func (pr *PushRelay) UpdateCredentials(cred pushCredentials) {
	if cred.DeviceID == "" || cred.DeviceSecret == "" {
		return
	}
	pr.mu.Lock()
	pr.credentials = cred
	pr.mu.Unlock()
	log.Printf("[Push] credentials updated (device_id=%s...)", cred.DeviceID[:min(8, len(cred.DeviceID))])
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// HasCredentials 报告是否具备触发推送所需的凭证。
func (pr *PushRelay) HasCredentials() bool {
	pr.mu.Lock()
	defer pr.mu.Unlock()
	return pr.credentials.DeviceID != "" && pr.credentials.DeviceSecret != ""
}

// SendCallPush sends a VoIP push to wake up iPhone for incoming call.
// callUUIDIn 为 server 侧通话 ID；若不是标准 UUID 则本地生成确定性替代并记录日志。
func (pr *PushRelay) SendCallPush(callerNumber, callUUIDIn string) error {
	pr.mu.Lock()
	// Dedup: don't send push for same call twice
	if pr.lastCallID == callUUIDIn {
		pr.mu.Unlock()
		return nil
	}
	pr.lastCallID = callUUIDIn
	cred := pr.credentials
	pr.mu.Unlock()

	if pr.relayURL == "" {
		return fmt.Errorf("relay URL not configured")
	}
	if cred.DeviceID == "" || cred.DeviceSecret == "" {
		return fmt.Errorf("push credentials missing (device_id/device_secret)")
	}

	// Worker 强制 call_uuid 为 UUID 格式；server 通话 ID 不保证是 UUID。
	callUUID := callUUIDIn
	if !isUUID(callUUID) {
		log.Printf("[Push] call id %q is not a UUID, generating one for relay", callUUIDIn)
		callUUID = randomUUID()
	}

	now := time.Now()
	body := map[string]any{
		"device_id":      cred.DeviceID,
		"device_secret":  cred.DeviceSecret,
		"event":          "incoming_call",
		"call_id":        callUUIDIn, // Worker 仅要求非空，保留原始通话 ID 便于对账
		"call_uuid":      callUUID,
		"generation":     1,
		"number":         callerNumber,
		"caller_name":    "",
		"issued_at":      now.Format(time.RFC3339Nano),
		"expires_at":     now.Add(60 * time.Second).Format(time.RFC3339Nano), // 60s ∈ (now-5s, now+120s]
		"media_transport": "legacy_pcm",
	}
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}

	url := fmt.Sprintf("%s/v1/events/call", pr.relayURL)
	req, err := http.NewRequest("POST", url, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := pr.httpClient.Do(req)
	if err != nil {
		log.Printf("[Push] relay request failed: %v", err)
		return fmt.Errorf("relay request failed: %v", err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 && resp.StatusCode != 202 {
		log.Printf("[Push] relay returned %d: %s", resp.StatusCode, string(respBody))
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

// isUUID 校验标准 8-4-4-4-12 十六进制 UUID 格式（Worker UUID_PATTERN 的小写等价实现）。
func isUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, c := range s {
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		default:
			isHex := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
			if !isHex {
				return false
			}
		}
	}
	return true
}

func randomUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		// 极端情况（无随机源）退化为时间戳 UUID，格式仍合法
		now := time.Now().UnixNano()
		for i := 0; i < 16; i++ {
			b[i] = byte(now >> (uint(i%8) * 8))
		}
	}
	// RFC 4122 version 4
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
