package main

import (
	"log"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// MicBridge receives iPhone mic audio (s16le 8kHz mono) and writes it to a Unix socket
// that the Swift App reads from and sends to BAIWANG USB.
//
// 改进：320字节帧对齐 + 有界队列 + 20ms节奏发送
type MicBridge struct {
	running atomic.Bool
	mu      sync.Mutex
	listener net.Listener
	conn     net.Conn

	// 帧对齐：累积字节直到凑够 320 字节一帧
	framerMu  sync.Mutex
	framerBuf []byte

	// 发送队列：最多缓存 N 帧
	sendMu    sync.Mutex
	sendQueue [][]byte
	maxQueue  int
}

const micSocketPath = "/tmp/djonehub-mic.sock"

func NewMicBridge() *MicBridge {
	return &MicBridge{
		maxQueue: 50, // 1 秒音频
	}
}

func (mb *MicBridge) Start() error {
	mb.mu.Lock()
	defer mb.mu.Unlock()

	if mb.running.Load() {
		return nil
	}

	os.Remove(micSocketPath)

	ln, err := net.Listen("unix", micSocketPath)
	if err != nil {
		log.Printf("mic socket listen error: %v", err)
		return err
	}
	mb.listener = ln
	mb.running.Store(true)

	// 重置缓冲
	mb.framerMu.Lock()
	mb.framerBuf = nil
	mb.framerMu.Unlock()
	mb.sendMu.Lock()
	mb.sendQueue = nil
	mb.sendMu.Unlock()

	// Accept Swift App client
	go func() {
		for mb.running.Load() {
			conn, err := ln.Accept()
			if err != nil {
				if mb.running.Load() {
					log.Printf("mic socket accept error: %v", err)
				}
				return
			}
			mb.mu.Lock()
			if mb.conn != nil {
				mb.conn.Close()
			}
			mb.conn = conn
			mb.mu.Unlock()
			log.Printf("mic socket client connected")
		}
	}()

	// 20ms 节奏发送 goroutine
	go mb.pumpSendQueue()

	log.Printf("mic socket listening: %s", micSocketPath)
	return nil
}

func (mb *MicBridge) Stop() {
	mb.mu.Lock()
	defer mb.mu.Unlock()

	if !mb.running.Load() {
		return
	}

	mb.running.Store(false)
	if mb.conn != nil {
		mb.conn.Close()
		mb.conn = nil
	}
	if mb.listener != nil {
		mb.listener.Close()
	}
	os.Remove(micSocketPath)
	log.Printf("mic socket stopped")
}

var micLogCount uint64
var micLogBytes uint64

// WriteFromiPhone receives raw PCM bytes from WebSocket.
// Aligns them into 320-byte frames and enqueues for paced sending.
func (mb *MicBridge) WriteFromiPhone(data []byte) {
	if !mb.running.Load() {
		return
	}

	micLogCount++
	micLogBytes += uint64(len(data))
	if micLogCount <= 3 || micLogCount%200 == 0 {
		log.Printf("[Mic] WebSocket上行 #%d: %d bytes (累计 %d bytes)", micLogCount, len(data), micLogBytes)
	}

	// 帧对齐：累积到 320 字节一帧
	mb.framerMu.Lock()
	mb.framerBuf = append(mb.framerBuf, data...)
	var frames [][]byte
	for len(mb.framerBuf) >= 320 {
		frame := make([]byte, 320)
		copy(frame, mb.framerBuf[:320])
		frames = append(frames, frame)
		mb.framerBuf = mb.framerBuf[320:]
	}
	mb.framerMu.Unlock()

	// 入队
	mb.sendMu.Lock()
	for _, f := range frames {
		mb.sendQueue = append(mb.sendQueue, f)
	}
	// 溢出丢最老
	for len(mb.sendQueue) > mb.maxQueue {
		mb.sendQueue = mb.sendQueue[1:]
	}
	mb.sendMu.Unlock()
}

// pumpSendQueue 20ms 节奏写一帧到 Unix socket
func (mb *MicBridge) pumpSendQueue() {
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	var writeCount uint64
	for {
		select {
		case <-ticker.C:
			if !mb.running.Load() {
				return
			}
			mb.sendMu.Lock()
			queueLen := len(mb.sendQueue)
			if queueLen == 0 {
				mb.sendMu.Unlock()
				continue
			}
			frame := mb.sendQueue[0]
			mb.sendQueue = mb.sendQueue[1:]
			mb.sendMu.Unlock()

			mb.mu.Lock()
			conn := mb.conn
			mb.mu.Unlock()
			if conn == nil {
				continue
			}
			conn.SetWriteDeadline(time.Now().Add(250 * time.Millisecond))
			_, err := conn.Write(frame)
			writeCount++
			if writeCount <= 3 || writeCount%200 == 0 {
				log.Printf("[Mic] 写入socket #%d: %d bytes, queue=%d, ws收=%d帧", writeCount, len(frame), queueLen, micLogCount)
			}
			if err != nil {
				log.Printf("mic socket write error: %v", err)
				mb.mu.Lock()
				if mb.conn == conn {
					mb.conn = nil
				}
				mb.mu.Unlock()
			}
		}
	}
}
