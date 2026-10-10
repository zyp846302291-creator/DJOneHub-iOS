import Foundation
import AVFoundation
import AudioToolbox
import UIKit

/// Receives audio frames from Mac via WebSocket and plays through iPhone speaker.
/// Also captures iPhone mic via AVAudioEngine.inputNode.
///
/// v2 改进（对齐 AirSIM，完整落地）：
/// - .voiceChat 模式 + setVoiceProcessingEnabled(true) → 系统 AEC + 降噪
/// - 48kHz 采集 → HPF(100Hz) + 线性插值降采样到 8kHz
/// - 下行自适应抖动缓冲（目标 20 帧 / 上限 50 帧 / 播放窗口预排 ≤12 帧）
/// - 320 字节帧对齐（8kHz × 20ms × 2bytes，跨消息边界）
/// - 上行 20ms 节奏发送（队列上限 50 包，丢弃 >1s 旧包，避免 TCP 积压）
class AudioReceiver: ObservableObject {
    @Published var isRunning = false
    @Published var isCallActive = false
    @Published var isMuted = false
    @Published var isSpeakerOn = false

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    private let sampleRate: Double = 8000
    private let channels: AVAudioChannelCount = 1

    private var frameLog = 0

    /// Callback to send mic audio data (s16le) back to Mac via WebSocket
    var onMicAudio: ((Data) -> Void)?

    // DSP 滤波状态（对齐 AirSIM VoiceCaptureConditioner）
    private var prevInput: Float = 0
    private var hpOutput: Float = 0
    private var dspInitialized = false

    // MARK: - 下行自适应抖动缓冲（v2）

    /// 每帧字节数：8kHz × 20ms × 2bytes
    private let frameBytes = 320
    /// 目标缓冲帧数（20 帧 = 400ms）
    private let jitterTarget = 20
    /// 缓冲上限（50 帧 = 1s）
    private let jitterMax = 50
    /// 播放窗口预排上限：最多排入 player 的未播帧数
    private let prefillMax = 12
    private var jitterFrames: [Data] = []
    private var scheduledFrames = 0
    private var jitterDropped = 0
    private var jitterUnderruns = 0
    private var jitterLogCount = 0
    private let jitterLock = NSLock()

    // MARK: - 上行 20ms 节奏发送（v2）

    private var micQueue: [Data] = []
    private let micQueueMax = 50
    private let micSendInterval = 0.02
    private var micSender: DispatchSourceTimer?
    private var micSendLogCount = 0
    private let micLock = NSLock()

    // MARK: - Engine Lifecycle

    func startEngine() {
        guard audioEngine == nil else { return }

        let session = AVAudioSession.sharedInstance()
        var useVoiceProcessing = false

        do {
            // 优先尝试 .voiceChat + VoiceProcessingIO（系统 AEC + 降噪）
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.allowBluetoothHFP])
            try session.setPreferredSampleRate(48_000)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
            useVoiceProcessing = true
            print("[Audio] session: .voiceChat, route=\(session.currentRoute.outputs.map { $0.portName })")
        } catch {
            // 回退到 .default 模式
            do {
                try session.setCategory(.playAndRecord, mode: .default,
                                         options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker])
                try session.setActive(true)
                print("[Audio] ⚠️ .voiceChat 失败，回退 .default: \(error)")
            } catch {
                print("[Audio] ⚠️ session error: \(error)")
            }
        }

        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: sampleRate,
                                      channels: channels,
                                      interleaved: false) else {
            print("[Audio] ❌ failed to create format")
            return
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 1.0
        player.volume = 1.0

        // 重置 DSP 和下行抖动缓冲
        dspInitialized = false
        prevInput = 0; hpOutput = 0
        jitterLock.lock()
        jitterFrames = []
        scheduledFrames = 0
        jitterDropped = 0
        jitterUnderruns = 0
        jitterLogCount = 0
        jitterLock.unlock()
        micLock.lock()
        micQueue = []
        micLock.unlock()

        let inputNode = engine.inputNode

        var tapOK = false
        if useVoiceProcessing {
            // AirSIM 方式：先启用 VoiceProcessingIO，再用新格式 installTap
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                // 关键：VPM 启用后重新查询输入格式！
                let vpmFormat = inputNode.outputFormat(forBus: 0)
                let tapFrames = AVAudioFrameCount(max(960, Int(vpmFormat.sampleRate * 0.02)))
                inputNode.installTap(onBus: 0, bufferSize: tapFrames, format: vpmFormat) { [weak self] buffer, _ in
                    self?.captureMicSamples(buffer)
                }
                tapOK = true
                print("[Audio] VoiceProcessingIO 已启用, format=\(vpmFormat.sampleRate)Hz, tapBuf=\(tapFrames)")
            } catch {
                print("[Audio] ⚠️ setVoiceProcessingEnabled 失败: \(error)")
                useVoiceProcessing = false
            }
        }

        if !tapOK {
            // 回退：用 SafeAudioTap
            let inputFormat = inputNode.outputFormat(forBus: 0)
            let tapFrames = AVAudioFrameCount(max(256, Int(inputFormat.sampleRate / 50)))
            tapOK = SafeAudioTap.safeInstallTap(with: inputNode, bus: 0, bufferSize: tapFrames, format: inputFormat) { [weak self] (buffer: AVAudioPCMBuffer?, when: AVAudioTime?) in
                guard let buffer = buffer else { return }
                self?.captureMicSamples(buffer)
            }
            if !tapOK {
                print("[Audio] ⚠️ installTap failed — uplink will use Mac mic")
            }
        }

        do {
            try engine.start()
            player.play()
            audioEngine = engine
            playerNode = player
            isRunning = true
            isCallActive = false
            frameLog = 0
            startMicSender()
            print("[Audio] engine started, tap=\(tapOK), vproc=\(useVoiceProcessing), route=\(session.currentRoute.outputs.map { $0.portName })")
        } catch {
            print("[Audio] engine start error: \(error)")
        }
    }

    func stopEngine() {
        stopRingback()
        stopMicSender()
        playerNode?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        isRunning = false
        isCallActive = false
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
        print("[Audio] engine stopped")
    }

    // MARK: - Convenience

    func start() { startEngine() }
    func stop() { stopEngine() }

    // MARK: - Speaker Toggle

    func toggleSpeaker() {
        let session = AVAudioSession.sharedInstance()
        do {
            if isSpeakerOn {
                try session.overrideOutputAudioPort(.none)
                print("[Audio] speaker OFF → earpiece")
            } else {
                try session.overrideOutputAudioPort(.speaker)
            }
            updateSpeakerState()
            print("[Audio] route: \(session.currentRoute.outputs.map { $0.portName })")
        } catch {
            print("[Audio] toggle error: \(error)")
        }
    }

    func updateSpeakerState() {
        let route = AVAudioSession.sharedInstance().currentRoute
        isSpeakerOn = route.outputs.contains { $0.portType == .builtInSpeaker }
    }

    var currentOutputName: String {
        let route = AVAudioSession.sharedInstance().currentRoute
        if let output = route.outputs.first { return output.portName }
        return "听筒"
    }

    // MARK: - Call Connected

    func callConnected() {
        guard !isCallActive else { return }
        isCallActive = true
        if let engine = audioEngine, !engine.isRunning {
            try? engine.start()
            playerNode?.play()
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] _ in
            self?.updateSpeakerState()
        }
        updateSpeakerState()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred()
        print("[Audio] call connected — route=\(AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portName })")
    }

    // MARK: - Ringback Tone (呼出时听到嘟嘟声)

    private var ringbackTimer: Timer?

    func startRingback() {
        guard ringbackTimer == nil, isRunning, let player = playerNode else { return }
        playRingbackBeep(player)
        ringbackTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, let p = self.playerNode else { return }
            self.playRingbackBeep(p)
        }
    }

    func stopRingback() {
        ringbackTimer?.invalidate()
        ringbackTimer = nil
    }

    private func playRingbackBeep(_ player: AVAudioPlayerNode) {
        let rate: Double = 8000
        let duration: Double = 1.0
        let frames = AVAudioFrameCount(rate * duration)
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        buf.frameLength = frames
        let data = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Float(i) / Float(rate)
            data[i] = sinf(2.0 * .pi * 440 * t) * 0.3
        }
        player.scheduleBuffer(buf)
    }

    // MARK: - Mic Capture (with DSP filtering, aligned AirSIM)

    private var micFrameCount = 0

    private func captureMicSamples(_ buffer: AVAudioPCMBuffer) {
        guard !isMuted,
              let channels = buffer.floatChannelData else { return }

        let srcRate = buffer.format.sampleRate
        let srcFrames = Int(buffer.frameLength)
        guard srcFrames > 0 else { return }

        micFrameCount += 1
        if micFrameCount <= 3 || micFrameCount % 500 == 0 {
            print("[Audio] mic帧 #\(micFrameCount): \(srcRate)Hz, \(srcFrames) samples")
        }

        let srcData = channels[0]

        // 轻量 DSP：只保留 HPF(100Hz) 去直流，不做 LPF（VPM 已处理降噪，
        // 8kHz 采样本身限制带宽，叠加 LPF 会导致声音发闷）
        var filtered = [Float](repeating: 0, count: srcFrames)
        if !dspInitialized {
            prevInput = 0; hpOutput = 0
            dspInitialized = true
        }

        let timeStep = 1.0 / srcRate
        let hpfRC = 1.0 / (2 * .pi * 100)
        let hpfAlpha = Float(hpfRC / (hpfRC + timeStep))

        for i in 0..<srcFrames {
            let sample = srcData[i]
            hpOutput = hpfAlpha * (hpOutput + sample - prevInput)
            prevInput = sample
            filtered[i] = max(-1.0, min(1.0, hpOutput))
        }

        // 线性插值降采样到 8kHz
        let dstRate = 8000.0
        let ratio = srcRate / dstRate
        let dstFrames = Int(Double(srcFrames) / ratio)
        guard dstFrames > 0 else { return }

        var pcm = Data(count: dstFrames * 2)
        pcm.withUnsafeMutableBytes { rawBuf in
            let dst = rawBuf.bindMemory(to: Int16.self)
            for i in 0..<dstFrames {
                let srcIdx = Int(Double(i) * ratio)
                let sample = filtered[min(srcIdx, srcFrames - 1)]
                let clamped = max(-1.0, min(1.0, sample))
                dst[i] = Int16(clamped * Float(Int16.max))
            }
        }

        // 入队，由 20ms 节奏发送器发出（避免 tap 即发导致 TCP 积压）
        micLock.lock()
        micQueue.append(pcm)
        if micQueue.count > micQueueMax {
            // 丢弃最旧的包（>1s 旧音频无意义）
            let overflow = micQueue.count - micQueueMax
            micQueue.removeFirst(overflow)
        }
        micLock.unlock()
    }

    // MARK: - 上行 20ms 节奏发送（v2）

    private func startMicSender() {
        stopMicSender()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + micSendInterval, repeating: micSendInterval)
        timer.setEventHandler { [weak self] in
            self?.tickMicSender()
        }
        timer.resume()
        micSender = timer
    }

    private func stopMicSender() {
        micSender?.cancel()
        micSender = nil
        micLock.lock()
        micQueue.removeAll()
        micLock.unlock()
    }

    private func tickMicSender() {
        // 静音时清空队列不发
        if isMuted {
            micLock.lock()
            micQueue.removeAll()
            micLock.unlock()
            return
        }

        micLock.lock()
        guard !micQueue.isEmpty, let onMic = onMicAudio else {
            micLock.unlock()
            return
        }
        let frame = micQueue.removeFirst()
        micLock.unlock()

        onMic(frame)

        micSendLogCount += 1
        if micSendLogCount <= 3 || micSendLogCount % 200 == 0 {
            micLock.lock()
            let depth = micQueue.count
            micLock.unlock()
            print("[Audio] mic 节奏发送 #\(micSendLogCount): \(frame.count)B, queue=\(depth)")
        }
    }

    // MARK: - Audio Frame Playback (v2: 自适应抖动缓冲 + 播放窗口预排)

    func handleAudioFrame(_ data: Data) {
        guard isRunning, data.count > 8 else { return }
        if data[0] == 0xFF && data[1] == 0xFF && data[2] == 0xFF && data[3] == 0xFF { return }

        frameLog += 1
        if frameLog <= 3 || frameLog % 200 == 0 {
            print("[Audio] frame #\(frameLog): \(data.count) B")
        }

        let pcmData = data.subdata(in: 8..<data.count)

        // 320B 帧对齐：跨消息/跨 read 边界切帧
        jitterLock.lock()
        for offset in stride(from: 0, to: pcmData.count - frameBytes + 1, by: frameBytes) {
            jitterFrames.append(pcmData.subdata(in: offset..<(offset + frameBytes)))
        }
        // 上限保护：超过 50 帧丢弃最旧（网络突发时防止延迟无限增大）
        if jitterFrames.count > jitterMax {
            jitterDropped += jitterFrames.count - jitterMax
            jitterFrames.removeFirst(jitterFrames.count - jitterMax)
        }
        let ready = jitterFrames.count >= jitterTarget
        jitterLock.unlock()

        // 攒够目标帧才开始播放（吸收网络抖动），此后持续排空
        if ready { drainJitter() }
    }

    /// 把抖动缓冲中的帧排入播放器，受预排窗口限制（最多 prefillMax 帧在途）
    private func drainJitter() {
        while true {
            jitterLock.lock()
            guard scheduledFrames < prefillMax, !jitterFrames.isEmpty else {
                // 空窗（underrun）统计
                if jitterFrames.isEmpty && scheduledFrames == 0 {
                    jitterUnderruns += 1
                }
                jitterLock.unlock()
                return
            }
            let frame = jitterFrames.removeFirst()
            jitterLock.unlock()

            schedulePCM(frame)

            jitterLogCount += 1
            if jitterLogCount % 300 == 0 {
                jitterLock.lock()
                print("[Audio] jitter: target=\(jitterTarget) buffered=\(jitterFrames.count) scheduled=\(scheduledFrames) dropped=\(jitterDropped) underruns=\(jitterUnderruns)")
                jitterLock.unlock()
            }
        }
    }

    private func schedulePCM(_ pcmData: Data) {
        guard let player = playerNode else { return }

        let sampleCount = pcmData.count / 2
        guard sampleCount > 0 else { return }

        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: sampleRate,
                                      channels: channels,
                                      interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt,
                                            frameCapacity: AVAudioFrameCount(sampleCount)) else { return }

        buffer.frameLength = AVAudioFrameCount(sampleCount)

        pcmData.withUnsafeBytes { rawBuf in
            let src = rawBuf.bindMemory(to: Int16.self)
            if let dst = buffer.floatChannelData {
                let floatDst = dst[0]
                for i in 0..<sampleCount {
                    floatDst[i] = Float(src[i]) / Float(Int16.max)
                }
            }
        }

        // 记录在途帧数；播完回调后继续排空抖动缓冲（播放窗口预排）
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.jitterLock.lock()
            self.scheduledFrames -= 1
            let hasMore = !self.jitterFrames.isEmpty
            self.jitterLock.unlock()
            if hasMore { self.drainJitter() }
        }
        jitterLock.lock()
        scheduledFrames += 1
        jitterLock.unlock()
    }
}
