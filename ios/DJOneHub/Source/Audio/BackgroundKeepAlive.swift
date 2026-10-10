import AVFoundation

/// Plays an inaudible 20Hz tone to keep the app alive in background.
///
/// ARCHITECTURE: When a call starts, this MUST be stopped before CallKit
/// activates the call AudioSession. The two sessions (.playback vs .voiceChat)
/// must NEVER coexist — CallKit is the sole AudioSession owner during calls.
class BackgroundKeepAlive {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[KeepAlive] session error: \(error)")
            return
        }

        let eng = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        eng.attach(playerNode)

        let sampleRate: Double = 44100
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sampleRate, channels: 1, interleaved: false)!

        let duration: Double = 2.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        if let data = buffer.floatChannelData {
            let amplitude: Float = 0.001
            for i in 0..<Int(frameCount) {
                let t = Float(i) / Float(sampleRate)
                data[0][i] = sinf(2.0 * .pi * 20.0 * t) * amplitude
            }
        }

        eng.connect(playerNode, to: eng.mainMixerNode, format: fmt)
        eng.mainMixerNode.outputVolume = 1.0

        playerNode.scheduleBuffer(buffer, at: nil, options: .loops)

        do {
            try eng.start()
            playerNode.play()
            engine = eng
            player = playerNode
            isRunning = true
            print("[KeepAlive] started — 20Hz tone, .playback category")
        } catch {
            print("[KeepAlive] engine error: \(error)")
        }
    }

    /// Full stop: engine + session release.
    /// CallKit will re-activate the session with .voiceChat when a call starts.
    func stop() {
        guard isRunning else { return }
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        isRunning = false
        // Release the .playback session so CallKit can cleanly own the next one
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        print("[KeepAlive] stopped + session released")
    }
}