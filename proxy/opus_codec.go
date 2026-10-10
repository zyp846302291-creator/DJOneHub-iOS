package main

import (
	"log"
	"sync"

	"github.com/hraban/opus"
)

const (
	opusSampleRate = 8000
	opusChannels   = 1
	opusBitrate    = 24000 // 24kbps — good speech quality for narrowband
	opusFrameMs    = 20    // 20ms frames = 160 samples at 8kHz
)

var (
	opusFrameSamples = opusSampleRate * opusFrameMs / 1000 // 160
	opusFrameBytes   = opusFrameSamples * 2                // 320 bytes s16le
)

// OpusEncoder wraps an opus.Encoder with thread-safe access.
type OpusEncoder struct {
	mu      sync.Mutex
	encoder *opus.Encoder
}

func NewOpusEncoder() (*OpusEncoder, error) {
	enc, err := opus.NewEncoder(opusSampleRate, opusChannels, opus.AppVoIP)
	if err != nil {
		return nil, err
	}
	enc.SetBitrate(opusBitrate)
	enc.SetComplexity(3) // 0-10, lower = less CPU
	log.Printf("[Opus] encoder created: %dHz, %dkbps, %dms frames", opusSampleRate, opusBitrate/1000, opusFrameMs)
	return &OpusEncoder{encoder: enc}, nil
}

// Encode converts s16le PCM to Opus.
func (e *OpusEncoder) Encode(pcm []byte) ([]byte, error) {
	// Convert s16le bytes to int16 samples
	samples := make([]int16, len(pcm)/2)
	for i := range samples {
		samples[i] = int16(pcm[i*2]) | int16(pcm[i*2+1])<<8
	}
	// Output buffer — max Opus frame is ~4000 bytes
	output := make([]byte, 4000)
	e.mu.Lock()
	n, err := e.encoder.Encode(samples, output)
	e.mu.Unlock()
	if err != nil {
		return nil, err
	}
	return output[:n], nil
}

// OpusDecoder wraps an opus.Decoder with thread-safe access.
type OpusDecoder struct {
	mu      sync.Mutex
	decoder *opus.Decoder
}

func NewOpusDecoder() (*OpusDecoder, error) {
	dec, err := opus.NewDecoder(opusSampleRate, opusChannels)
	if err != nil {
		return nil, err
	}
	log.Printf("[Opus] decoder created: %dHz", opusSampleRate)
	return &OpusDecoder{decoder: dec}, nil
}

// Decode converts Opus to s16le PCM.
func (d *OpusDecoder) Decode(opusData []byte) ([]byte, error) {
	samples := make([]int16, opusFrameSamples)
	d.mu.Lock()
	n, err := d.decoder.Decode(opusData, samples)
	d.mu.Unlock()
	if err != nil {
		return nil, err
	}
	// Convert int16 samples to s16le bytes
	pcm := make([]byte, n*2)
	for i := 0; i < n; i++ {
		pcm[i*2] = byte(samples[i])
		pcm[i*2+1] = byte(samples[i] >> 8)
	}
	return pcm, nil
}