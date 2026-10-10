package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

type AudioBridge struct {
	FrameCh chan []byte

	running atomic.Bool
	mu      sync.Mutex
	stopCh  chan struct{}
	conn    net.Conn

	sampleRate  int
	channels    int
	frameSizeMs int

	// 抖动缓冲（对齐 AirSIM cloudPCMSpeechBuffer）
	jitterMu      sync.Mutex
	jitterFrames  [][]byte
	jitterTarget   int
	jitterPrimed   bool
	jitterLastArrival time.Time
	jitterJitter   float64
	jitterDropped  uint64
	jitterUnderruns uint64
}

const audioSocketPath = "/tmp/djonehub-audio.sock"

func NewAudioBridge(_, _ int) *AudioBridge {
	return &AudioBridge{
		FrameCh:     make(chan []byte, 100),
		sampleRate:  8000,
		channels:    1,
		frameSizeMs: 20,
		jitterTarget: 10,
	}
}

func (ab *AudioBridge) Start() error {
	ab.mu.Lock()
	defer ab.mu.Unlock()

	if ab.running.Load() {
		return fmt.Errorf("audio bridge already running")
	}

	ab.stopCh = make(chan struct{})
	ab.running.Store(true)

	// 重置抖动缓冲
	ab.jitterMu.Lock()
	ab.jitterFrames = nil
	ab.jitterPrimed = false
	ab.jitterTarget = 10
	ab.jitterLastArrival = time.Time{}
	ab.jitterJitter = 0
	ab.jitterMu.Unlock()

	go ab.streamFromSocket()
	go ab.pumpJitterBuffer()

	log.Printf("audio bridge started (jitter buffer target=%d)", ab.jitterTarget)
	return nil
}

func (ab *AudioBridge) Stop() {
	ab.mu.Lock()
	defer ab.mu.Unlock()

	if !ab.running.Load() {
		return
	}

	ab.running.Store(false)
	close(ab.stopCh)

	if ab.conn != nil {
		ab.conn.Close()
	}

	for len(ab.FrameCh) > 0 {
		<-ab.FrameCh
	}

	log.Printf("audio bridge stopped")
}

func (ab *AudioBridge) IsRunning() bool {
	return ab.running.Load()
}

// enqueueJitter 把从 Unix socket 读到的完整帧放入抖动缓冲
func (ab *AudioBridge) enqueueJitter(frame []byte) {
	ab.jitterMu.Lock()
	defer ab.jitterMu.Unlock()

	now := time.Now()
	if !ab.jitterLastArrival.IsZero() {
		variation := now.Sub(ab.jitterLastArrival).Seconds() - 0.02
		if variation < 0 {
			variation = -variation
		}
		ab.jitterJitter += (variation - ab.jitterJitter) / 16
		desired := 10 + int(4*ab.jitterJitter/0.02)
		if desired > 30 {
			desired = 30
		}
		if desired > ab.jitterTarget {
			ab.jitterTarget = desired
		}
	}
	ab.jitterLastArrival = now

	copied := make([]byte, len(frame))
	copy(copied, frame)
	ab.jitterFrames = append(ab.jitterFrames, copied)

	// 溢出保护：最多 50 帧
	if len(ab.jitterFrames) > 50 {
		ab.jitterFrames = ab.jitterFrames[1:]
		ab.jitterDropped++
	}
}

// popJitter 从抖动缓冲取一帧，未 prime 完返回 nil
func (ab *AudioBridge) popJitter() []byte {
	ab.jitterMu.Lock()
	defer ab.jitterMu.Unlock()

	if !ab.jitterPrimed {
		if len(ab.jitterFrames) >= ab.jitterTarget {
			ab.jitterPrimed = true
		} else {
			return nil
		}
	}

	if len(ab.jitterFrames) == 0 {
		ab.jitterPrimed = false
		ab.jitterUnderruns++
		ab.jitterTarget += 5
		if ab.jitterTarget > 30 {
			ab.jitterTarget = 30
		}
		return nil
	}

	frame := ab.jitterFrames[0]
	ab.jitterFrames = ab.jitterFrames[1:]
	return frame
}

// pumpJitterBuffer 20ms 节奏从抖动缓冲取帧，加上序号头发到 FrameCh
func (ab *AudioBridge) pumpJitterBuffer() {
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	seq := uint32(0)
	for {
		select {
		case <-ab.stopCh:
			return
		case <-ticker.C:
			if !ab.running.Load() {
				return
			}
			frame := ab.popJitter()
			if frame == nil {
				continue
			}
			// 加 8 字节头（序号 + 时间戳），保持和原来一样的格式
			packet := make([]byte, 8+len(frame))
			binary.BigEndian.PutUint32(packet[0:4], seq)
			binary.BigEndian.PutUint32(packet[4:8], uint32(time.Now().UnixMilli()))
			copy(packet[8:], frame)
			select {
			case ab.FrameCh <- packet:
			case <-ab.stopCh:
				return
			default:
				// FrameCh 满了，丢这帧
			}
			seq++
		}
	}
}

func (ab *AudioBridge) streamFromSocket() {
	s16FrameBytes := ab.sampleRate * ab.channels * 2 * ab.frameSizeMs / 1000

	for ab.running.Load() {
		conn := ab.connectWithRetry()
		if conn == nil {
			return
		}
		ab.conn = conn
		log.Printf("audio socket connected")

		s16Buf := make([]byte, s16FrameBytes)

		for ab.running.Load() {
			conn.SetReadDeadline(time.Now().Add(5 * time.Second))
			_, err := io.ReadFull(conn, s16Buf)
			if err != nil {
				if ab.running.Load() {
					log.Printf("audio socket lost (%v), reconnecting...", err)
				}
				conn.Close()
				ab.mu.Lock()
				if ab.conn == conn {
					ab.conn = nil
				}
				ab.mu.Unlock()
				break
			}
			// 放入抖动缓冲，不再直接发到 FrameCh
			ab.enqueueJitter(s16Buf)
		}
	}
}

func (ab *AudioBridge) connectWithRetry() net.Conn {
	for ab.running.Load() {
		conn, err := net.DialTimeout("unix", audioSocketPath, 1*time.Second)
		if err == nil {
			return conn
		}
		time.Sleep(100 * time.Millisecond)
	}
	return nil
}
