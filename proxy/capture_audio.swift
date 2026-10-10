#!/usr/bin/env swift
// capture_audio.swift — Capture system audio using ScreenCaptureKit
// Outputs raw PCM to stdout

import ScreenCaptureKit
import Foundation
import CoreMedia

var frameCount: Int = 0
var wroteFormat = false

@available(macOS 12.3, *)
class AudioCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid else { return }

        if !wroteFormat, let fmt = sampleBuffer.formatDescription,
           let asbd = fmt.audioStreamBasicDescription {
            let rate = asbd.mSampleRate
            let ch = asbd.mChannelsPerFrame
            let bps = asbd.mBitsPerChannel
            fputs("[capture] format: \(rate)Hz, \(ch)ch, \(bps)bit\n", stderr)
            wroteFormat = true
        }

        guard let blockBuffer = sampleBuffer.dataBuffer else { return }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return }

        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset: Int = 0
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == noErr, let ptr = dataPointer else { return }

        let actual = min(lengthAtOffset, totalLength)
        _ = fwrite(ptr, 1, actual, stdout)

        frameCount += 1
        if frameCount <= 3 || frameCount % 500 == 0 {
            fputs("[capture] frame #\(frameCount): \(actual) bytes\n", stderr)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("[capture] stopped: \(error)\n", stderr)
        exit(1)
    }
}

@available(macOS 12.3, *)
func main() async {
    let args = CommandLine.arguments
    let targetPID: pid_t? = args.count >= 2 ? Int32(args[1]) : nil

    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        let filter: SCContentFilter
        if let pid = targetPID, let app = content.applications.first(where: { $0.processID == pid }) {
            filter = SCContentFilter(display: content.displays[0], including: [app], exceptingWindows: [])
            fputs("[capture] targeting PID \(pid) (\(app.applicationName))\n", stderr)
        } else {
            let allApps: [SCRunningApplication] = content.applications
            filter = SCContentFilter(display: content.displays[0], including: allApps, exceptingWindows: [])
            fputs("[capture] all system audio (\(allApps.count) apps)\n", stderr)
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 8000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let capturer = AudioCapturer()

        try stream.addStreamOutput(capturer, type: .audio, sampleHandlerQueue: DispatchQueue.global(qos: .userInteractive))
        try await stream.startCapture()

        fputs("[capture] ✅ ScreenCaptureKit capturing audio → stdout\n", stderr)
        setbuf(stdout, nil)

        signal(SIGINT) { _ in
            fputs("\n[capture] \(frameCount) frames.\n", stderr)
            exit(0)
        }

        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    } catch {
        fputs("[capture] error: \(error)\n", stderr)
        exit(1)
    }
}

if #available(macOS 12.3, *) {
    Task { await main() }
    RunLoop.main.run()
} else {
    fputs("Error: macOS 12.3+ required\n", stderr)
    exit(1)
}
