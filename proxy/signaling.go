package main

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

// Signaling message types between iPhone and Mac
type SignalMessage struct {
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload,omitempty"`
}

// Call state pushed to iPhone
type CallStatePush struct {
	Active  *CallInfo   `json:"active"`
	History []CallInfo  `json:"history,omitempty"`
	Audio   *AudioState `json:"audio,omitempty"`
	Module  *ModuleInfo `json:"module,omitempty"`
}

type CallInfo struct {
	ID        string `json:"id"`
	Direction string `json:"direction"`
	State     string `json:"state"`
	Number    string `json:"number,omitempty"`
	StartedAt string `json:"started_at,omitempty"`
	Missed    bool   `json:"missed,omitempty"`
}

type AudioState struct {
	Running bool `json:"running"`
}

type ModuleInfo struct {
	Operator string `json:"operator"`
	Signal   int    `json:"signal_dbm"`
	Network  string `json:"network_mode"`
	SIMReady bool   `json:"sim_inserted"`
}

type HubSignaling struct {
	upstream  string
	upgrader  websocket.Upgrader
	clients   map[*wsClient]bool
	mu        sync.RWMutex
	pollDone  chan struct{}
	audio     *AudioBridge
	micBridge *MicBridge
	pushRelay *PushRelay
	// lastSMSTimestamp 是已通知过 iPhone 的最新收件时间；为空表示还没初始化
	lastSMSTimestamp string
}

// SMSInfo 是推给 iPhone 的单条收到的短信（字段与后端 /api/sms 一致）
type SMSInfo struct {
	Sender    string `json:"sender"`
	Content   string `json:"content"`
	Timestamp string `json:"timestamp"`
}

type wsClient struct {
	conn     *websocket.Conn
	send     chan []byte
	hub      *HubSignaling
	mu       sync.Mutex
	remoteIP string
	stopCh   chan struct{}
	muted    atomic.Bool // iPhone mic mute state
}

func NewHubSignaling(upstream string) *HubSignaling {
	h := &HubSignaling{
		upstream:  upstream,
		clients:   make(map[*wsClient]bool),
		audio:     NewAudioBridge(5758, 5759), // Mac listens on 5758, iPhone on 5759
		micBridge: NewMicBridge(),
		upgrader: websocket.Upgrader{
			CheckOrigin: func(r *http.Request) bool { return true },
		},
	}
	return h
}

func (h *HubSignaling) ServeWS(w http.ResponseWriter, r *http.Request) {
	conn, err := h.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("ws upgrade failed: %v", err)
		return
	}

	client := &wsClient{
		conn:     conn,
		send:     make(chan []byte, 64),
		hub:      h,
		remoteIP: hostFromRemoteAddr(r.RemoteAddr),
		stopCh:   make(chan struct{}),
	}

	h.mu.Lock()
	h.clients[client] = true
	clientCount := len(h.clients)
	h.mu.Unlock()

	log.Printf("iPhone connected via WebSocket (total: %d)", clientCount)

	// Send initial state immediately
	go client.sendFullState()

	// Start write pump
	go client.writePump()

	// Read pump (handles incoming commands from iPhone)
	client.readPump()
}

func (c *wsClient) readPump() {
	defer func() {
		close(c.stopCh)
		c.hub.mu.Lock()
		delete(c.hub.clients, c)
		c.hub.mu.Unlock()
		c.conn.Close()
		log.Printf("iPhone disconnected (remaining: %d)", len(c.hub.clients))
	}()

	c.conn.SetReadLimit(4096)
	c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		return nil
	})

	for {
		msgType, message, err := c.conn.ReadMessage()
		if err != nil {
			break
		}

		// Binary message = mic audio from iPhone (s16le PCM)
		if msgType == websocket.BinaryMessage && c.hub.micBridge != nil {
			if !c.muted.Load() {
				c.hub.micBridge.WriteFromiPhone(message)
			}
			continue
		}

		var msg SignalMessage
		if err := json.Unmarshal(message, &msg); err != nil {
			log.Printf("invalid signal message: %v", err)
			continue
		}

		c.handleCommand(msg)
	}
}

func (c *wsClient) handleCommand(msg SignalMessage) {
	switch msg.Type {
	case "dial":
		var payload struct {
			Number string `json:"number"`
		}
		if err := json.Unmarshal(msg.Payload, &payload); err != nil || payload.Number == "" {
			c.sendError("dial", "missing number")
			return
		}
		c.proxyToHub("POST", "/api/calls/dial", map[string]string{"number": payload.Number})

	case "answer":
		c.proxyToHub("POST", "/api/calls/answer", nil)

	case "hangup":
		c.proxyToHub("POST", "/api/calls/hangup", nil)

	case "reject":
		c.proxyToHub("POST", "/api/calls/reject", nil)

	case "dtmf":
		var payload struct {
			Digit string `json:"digit"`
		}
		if err := json.Unmarshal(msg.Payload, &payload); err != nil {
			c.sendError("dtmf", "missing digit")
			return
		}
		c.proxyToHub("POST", "/api/calls/dtmf", map[string]string{"digit": payload.Digit})

	case "mute":
		var payload struct {
			Muted bool `json:"muted"`
		}
		json.Unmarshal(msg.Payload, &payload)
		c.muted.Store(payload.Muted)
		c.proxyToHub("POST", "/api/calls/audio/mute", map[string]bool{"muted": payload.Muted})
		log.Printf("mic mute: %v", payload.Muted)

	case "audio/start":
		log.Printf("audio/start requested")
		// Start mic bridge (iPhone mic → Swift App)
		c.hub.micBridge.Start()
		// Start bridge if not running, or just reattach forwarding if already running
		err := c.hub.audio.Start()
		if err != nil && err.Error() == "audio bridge already running" {
			log.Printf("bridge already running, reattaching forwarding → iPhone")
			go c.forwardAudioFrames()
			c.sendMessage(SignalMessage{Type: "audio/started"})
		} else if err != nil {
			c.sendError("audio/start", err.Error())
		} else {
			c.sendMessage(SignalMessage{Type: "audio/started"})
			go c.forwardAudioFrames()
		}

	case "audio/stop":
		c.hub.audio.Stop()
		c.hub.micBridge.Stop()
		c.sendMessage(SignalMessage{Type: "audio/stopped"})

	case "history_clear":
		var payload struct {
			ID string `json:"id"`
		}
		json.Unmarshal(msg.Payload, &payload)
		path := "/api/calls/history"
		if payload.ID != "" {
			path += "?id=" + url.QueryEscape(payload.ID)
		}
		c.proxyToHub("DELETE", path, nil)

	case "ping":
		c.sendMessage(SignalMessage{Type: "pong"})

	case "push_credentials":
		// iPhone 上报推送凭证（与 App 注册 Worker 时相同的 device_id/device_secret），
		// proxy 触发来电 VoIP push 时使用。注册失败无妨，仅记录。
		var payload pushCredentials
		if err := json.Unmarshal(msg.Payload, &payload); err != nil {
			log.Printf("invalid push_credentials payload: %v", err)
			return
		}
		if c.hub.pushRelay != nil {
			c.hub.pushRelay.UpdateCredentials(payload)
		} else {
			log.Printf("push relay not configured, ignoring push_credentials")
		}

	default:
		log.Printf("unknown signal type: %s", msg.Type)
	}
}

func (c *wsClient) proxyToHub(method, path string, body interface{}) {
	var req *http.Request
	var err error
	if body != nil {
		data, _ := json.Marshal(body)
		req, err = http.NewRequest(method, c.hub.upstream+path, bytes.NewReader(data))
		req.Header.Set("Content-Type", "application/json")
	} else {
		req, err = http.NewRequest(method, c.hub.upstream+path, nil)
	}
	if err != nil {
		c.sendError(path, err.Error())
		return
	}

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		c.sendError(path, err.Error())
		return
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)

	// mute 转发的 /api/calls/audio/mute 在部分 server 版本不存在，
	// 静默降级（本地 muted 标志已生效，足以静音 iPhone→Mac 上行）。
	if resp.StatusCode == http.StatusNotFound {
		log.Printf("upstream has no %s route (ignored)", path)
		return
	}

	c.sendMessage(SignalMessage{
		Type:    "api_response",
		Payload: json.RawMessage(respBody),
	})

	// After any call action, push updated state
	go c.sendFullState()
}

// forwardAudioFrames reads audio frames from the bridge channel
// and writes them directly to WebSocket, using mu to prevent concurrent writes.
func (c *wsClient) forwardAudioFrames() {
	log.Printf("audio frame forwarding started → iPhone")
	for {
		select {
		case frame, ok := <-c.hub.audio.FrameCh:
			if !ok {
				log.Printf("audio frame forwarding stopped (channel closed)")
				return
			}
			c.mu.Lock()
			c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			err := c.conn.WriteMessage(websocket.BinaryMessage, frame)
			c.mu.Unlock()
			if err != nil {
				log.Printf("audio frame write error: %v", err)
				return
			}
		case <-c.stopCh:
			log.Printf("audio frame forwarding cancelled (client disconnected)")
			return
		}
	}
}

func (c *wsClient) sendFullState() {
	state := c.fetchHubState()
	if state == nil {
		return
	}
	data, _ := json.Marshal(state)
	c.sendMessage(SignalMessage{
		Type:    "call_state",
		Payload: json.RawMessage(data),
	})
}

func (c *wsClient) fetchHubState() *CallStatePush {
	httpClient := &http.Client{Timeout: 3 * time.Second}

	state := &CallStatePush{}

	// Fetch call status
	if resp, err := httpClient.Get(c.hub.upstream + "/api/calls/status"); err == nil {
		defer resp.Body.Close()
		if body, err := io.ReadAll(resp.Body); err == nil {
			var callData struct {
				Active  *CallInfo  `json:"active"`
				History []CallInfo `json:"history"`
				Audio   AudioState `json:"audio"`
			}
			if json.Unmarshal(body, &callData) == nil {
				state.Active = callData.Active
				state.History = callData.History
				state.Audio = &callData.Audio
			}
		}
	}

	// Fetch module status
	if resp, err := httpClient.Get(c.hub.upstream + "/api/status"); err == nil {
		defer resp.Body.Close()
		if body, err := io.ReadAll(resp.Body); err == nil {
			var mod ModuleInfo
			if json.Unmarshal(body, &mod) == nil {
				state.Module = &mod
			}
		}
	}

	return state
}

func (c *wsClient) sendMessage(msg SignalMessage) {
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	select {
	case c.send <- data:
	default:
		// Channel full, drop message
	}
}

func (c *wsClient) sendError(action, detail string) {
	data, _ := json.Marshal(map[string]string{"action": action, "error": detail})
	c.sendMessage(SignalMessage{
		Type:    "error",
		Payload: json.RawMessage(data),
	})
}

func (c *wsClient) writePump() {
	ticker := time.NewTicker(30 * time.Second)
	defer func() {
		ticker.Stop()
		c.conn.Close()
	}()

	for {
		select {
		case message, ok := <-c.send:
			c.mu.Lock()
			c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if !ok {
				c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				c.mu.Unlock()
				return
			}
			msgType := websocket.TextMessage
			if len(message) > 0 && message[0] != '{' {
				msgType = websocket.BinaryMessage
			}
			err := c.conn.WriteMessage(msgType, message)
			c.mu.Unlock()
			if err != nil {
				return
			}

		case <-ticker.C:
			c.mu.Lock()
			c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			err := c.conn.WriteMessage(websocket.PingMessage, nil)
			c.mu.Unlock()
			if err != nil {
				return
			}
		}
	}
}

// StatePoller periodically polls DJOneHub and pushes state to all connected clients
func (h *HubSignaling) StartStatePoller(interval time.Duration) {
	h.pollDone = make(chan struct{})
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-h.pollDone:
				return
			case <-ticker.C:
				h.broadcastState()
			}
		}
	}()
}

func (h *HubSignaling) broadcastState() {
	h.mu.RLock()
	if len(h.clients) == 0 {
		h.mu.RUnlock()
		return
	}
	h.mu.RUnlock()

	h.pollAndBroadcastSMS()

	h.mu.RLock()
	if len(h.clients) == 0 {
		h.mu.RUnlock()
		return
	}

	// Fetch state once
	httpClient := &http.Client{Timeout: 3 * time.Second}
	state := &CallStatePush{}

	if resp, err := httpClient.Get(h.upstream + "/api/calls/status"); err == nil {
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		var callData struct {
			Active  *CallInfo  `json:"active"`
			History []CallInfo `json:"history"`
			Audio   AudioState `json:"audio"`
		}
		if json.Unmarshal(body, &callData) == nil {
			state.Active = callData.Active
			state.History = callData.History
			state.Audio = &callData.Audio
		}
	}

	if resp, err := httpClient.Get(h.upstream + "/api/status"); err == nil {
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		var mod ModuleInfo
		if json.Unmarshal(body, &mod) == nil {
			state.Module = &mod
		}
	}

	data, _ := json.Marshal(SignalMessage{
		Type:    "call_state",
		Payload: json.RawMessage(func() []byte { d, _ := json.Marshal(state); return d }()),
	})

	clients := make([]*wsClient, 0, len(h.clients))
	for c := range h.clients {
		clients = append(clients, c)
	}
	h.mu.RUnlock()

	for _, c := range clients {
		c.mu.Lock()
		select {
		case c.send <- data:
		default:
		}
		c.mu.Unlock()
	}

	// Push relay: send VoIP push if incoming call and no iPhone connected.
	// 兼容 server 侧来电状态值：incoming / waiting / ringing（B4 仲裁前的防御式处理）
	if h.pushRelay != nil && state.Active != nil &&
		state.Active.Direction == "incoming" &&
		(state.Active.State == "ringing" || state.Active.State == "incoming" || state.Active.State == "waiting") &&
		len(clients) == 0 {
		callUUID := state.Active.ID
		if callUUID == "" {
			callUUID = "call-" + time.Now().Format("20060102-150405")
		}
		// 推送失败在此记录（此前 go 起的调用返回值被丢弃，失败无任何日志）
		go func(number, id string) {
			if err := h.pushRelay.SendCallPush(number, id); err != nil {
				log.Printf("[Push] incoming call push failed: %v", err)
			}
		}(state.Active.Number, callUUID)
	}

	// Reset push dedup when call ends
	if h.pushRelay != nil && state.Active == nil {
		h.pushRelay.ResetDedup()
	}
}

// pollAndBroadcastSMS 检查后端收件箱，把新到的短信推给所有连着的 iPhone。
//
// 后端本身没有「新短信」事件，这里只能按时间戳比对：
//   - 代理启动后第一次只记录基线、不推送，否则会把历史短信当成新短信全部弹出；
//   - 后端不可达时不更新基线，避免恢复后把旧短信重推一遍；
//   - 收件箱被清空后基线跟着下降，否则之后的新短信会因「不比基线新」被漏掉。
//
// 已知局限：后端时间戳只到秒。若清空后同一秒内又收到新短信，这条会被漏掉。
func (h *HubSignaling) pollAndBroadcastSMS() {
	httpClient := &http.Client{Timeout: 3 * time.Second}
	resp, err := httpClient.Get(h.upstream + "/api/sms")
	if err != nil {
		return
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil || resp.StatusCode != http.StatusOK {
		return
	}
	var inbox []SMSInfo
	if err := json.Unmarshal(body, &inbox); err != nil {
		return
	}

	h.mu.Lock()
	baseline := h.lastSMSTimestamp
	fresh := h.lastSMSTimestamp == ""
	var latest string
	var newMessages []SMSInfo
	for _, m := range inbox {
		if m.Timestamp > latest {
			latest = m.Timestamp
		}
		if fresh || m.Timestamp > baseline {
			newMessages = append(newMessages, m)
		}
	}
	if latest != "" || len(inbox) == 0 {
		h.lastSMSTimestamp = latest
	}
	clients := make([]*wsClient, 0, len(h.clients))
	for c := range h.clients {
		clients = append(clients, c)
	}
	h.mu.Unlock()

	if fresh || len(newMessages) == 0 || len(clients) == 0 {
		return
	}

	// 一次汇总推送，避免一条短信占满客户端的发送通道
	payload, err := json.Marshal(newMessages)
	if err != nil {
		return
	}
	msg := SignalMessage{
		Type:    "sms_received",
		Payload: payload,
	}
	for _, c := range clients {
		c.sendMessage(msg)
	}
}

func (h *HubSignaling) ClientCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.clients)
}

func (h *HubSignaling) SetPushRelay(relay *PushRelay) {
	h.pushRelay = relay
}

// hostFromRemoteAddr 从 RemoteAddr 安全提取主机部分（兼容 IPv6 与异常格式）。
func hostFromRemoteAddr(remoteAddr string) string {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return remoteAddr
	}
	return host
}
