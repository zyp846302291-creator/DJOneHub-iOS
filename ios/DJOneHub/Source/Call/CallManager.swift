import Foundation
import Combine
import AVFoundation
import UIKit

extension Notification.Name {
    /// WebSocket 信令重连成功（UI 页面监听后自动重拉状态）
    static let djonehubSignalingDidConnect = Notification.Name("djonehubSignalingDidConnect")
}

/// Bridges SignalingClient (WebSocket ↔ Mac) and CallKitManager (iOS system call UI).
/// This is the central coordinator for all call operations.
class CallManager: ObservableObject {
    @Published var isConnected = false
    @Published var activeCall: CallInfo?
    @Published var callHistory: [CallInfo] = []
    @Published var moduleInfo: ModuleInfo?
    @Published var lastError: String?

    var demoMode: Bool = false

    let signaling: SignalingClient
    let callKit: CallKitManager
    let audioReceiver = AudioReceiver()

    // Track whether this device initiated the current call
    private var localInitiated = false
    private var isHangingUp = false
    /// 挂断后等待服务器确认的兜底定时器：超时后强制复位 isHangingUp，
    /// 避免服务器无响应（断线）时永远屏蔽来电 CallKit 上报。
    private var hangupWatchdog: Timer?
    private var pendingOutgoingNumber: String?
    // Track if CallKit "connected" has been reported for current call
    private var callReportedConnected = false
    // Call duration tracking
    @Published var callConnectTime: Date?
    private var callDurationTimer: Timer?
    // Suppress first-launch disconnect error
    private var hasConnectedOnce = false

    init(serverURL: URL) {
        self.signaling = SignalingClient(serverURL: serverURL)
        self.callKit = CallKitManager()
        self.signaling.delegate = self
        self.callKit.delegate = self

        // VoIP push 到达时由 PushKitManager 同步上报 CallKit（Apple 规范：
        // 必须在 PushKit completion 之前调用 reportNewIncomingCall）
        PushKitManager.shared.callKitReporter = { [weak self] caller, uuid in
            guard let self = self else { return }
            self.signaling.keepAlive.stop()
            self.callKit.reportIncomingCall(number: caller, uuid: uuid)
        }

        // Wire audio frames from WebSocket to AudioReceiver
        self.signaling.onAudioFrame = { [weak self] data in
            self?.audioReceiver.handleAudioFrame(data)
        }

        // Wire mic audio from iPhone to WebSocket (reverse path)
        self.audioReceiver.onMicAudio = { [weak self] pcm in
            self?.signaling.sendAudioData(pcm)
        }
    }

    func connect() {
        if demoMode {
            // Demo mode: simulate connected state with mock data
            DispatchQueue.main.async {
                self.isConnected = true
                self.hasConnectedOnce = true
                self.lastError = nil
                self.moduleInfo = ModuleInfo(operator_name: "中国联通", signal_dbm: -69, network_mode: "LTE", sim_inserted: true)
                self.callHistory = [
                    CallInfo(id: "demo-1", direction: "outgoing", state: "ended", number: "10086", started_at: "2026-10-17 09:15", missed: false),
                    CallInfo(id: "demo-2", direction: "incoming", state: "ended", number: "13800138000", started_at: "2026-10-16 18:42", missed: false),
                    CallInfo(id: "demo-3", direction: "incoming", state: "ended", number: "10010", started_at: "2026-10-16 09:30", missed: true)
                ]
            }
            return
        }
        signaling.connect()
    }

    func disconnect() {
        if demoMode { return }
        signaling.disconnect()
    }

    // MARK: - User Actions

    func dial(number: String) {
        guard !number.isEmpty else { return }
        lastError = nil
        localInitiated = true
        pendingOutgoingNumber = number

        // Immediately show call UI (don't wait for server state push)
        let localCall = CallInfo(id: "local-\(UUID().uuidString)",
                                 direction: "outgoing", state: "dialing",
                                 number: number, started_at: nil, missed: nil)

        if !demoMode {
            callKit.reportOutgoingCall(number: number)
        }

        DispatchQueue.main.async {
            self.activeCall = localCall
        }

        if demoMode {
            // Demo mode: simulate call connecting after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, self.activeCall != nil else { return }
                self.activeCall = CallInfo(id: localCall.id, direction: "outgoing", state: "active",
                                           number: number, started_at: nil, missed: nil)
                self.callConnectTime = Date()
                self.callDurationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    DispatchQueue.main.async { self?.objectWillChange.send() }
                }
            }
        } else {
            signaling.dial(number: number)
        }
    }

    func answer() {
        lastError = nil
        // Use CallKit to answer — keeps CallKit UI active after answering
        callKit.answerCall()
        // Note: signaling.answer() is called from callKit(_:didAnswerCall:) delegate
    }

    func hangup() {
        // Immediately clear call UI and block server state until confirmed ended
        localInitiated = false
        isHangingUp = true
        startHangupWatchdog()
        if !demoMode {
            callKit.endCall()
        }
        stopCallTimer()
        DispatchQueue.main.async {
            self.activeCall = nil
            self.audioReceiver.isMuted = false // 新通话默认不静音
        }
        if !demoMode {
            signaling.hangup()
        }
    }

    /// 挂断兜底：8 秒内未收到服务器 ended 确认则强制复位，恢复来电处理
    private func startHangupWatchdog() {
        hangupWatchdog?.invalidate()
        hangupWatchdog = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            guard let self = self, self.isHangingUp else { return }
            print("[CallManager] hangup confirm timeout — resetting isHangingUp")
            self.isHangingUp = false
        }
    }

    func reject() {
        if !demoMode {
            signaling.reject()
        }
        // callKit.endCall()
    }

    func sendDTMF(digit: String) {
        if !demoMode {
            signaling.sendDTMF(digit: digit)
        }
    }

    func toggleMute(muted: Bool) {
        audioReceiver.isMuted = muted
        if !demoMode {
            signaling.toggleMute(muted: muted)
        }
    }

    /// 清空全部通话记录（本地 + 服务器）
    func clearHistory() {
        callHistory = []
        if !demoMode {
            signaling.clearHistory()
        }
    }

    /// 删除单条通话记录（本地 + 服务器）
    func removeHistory(id: String?) {
        guard let id else { return }
        callHistory.removeAll { $0.id == id }
        if !demoMode {
            signaling.clearHistory(id: id)
        }
    }
}

// MARK: - SignalingClientDelegate

extension CallManager: SignalingClientDelegate {
    func signalingDidConnect(_ client: SignalingClient) {
        DispatchQueue.main.async {
            self.isConnected = true
            self.hasConnectedOnce = true
            self.lastError = nil
            // WebSocket 重连成功 → 广播通知：概览等页面据此自动重拉状态
            // （修复：App 断线重连后状态页不刷新运营商数据的 bug）
            NotificationCenter.default.post(name: .djonehubSignalingDidConnect, object: nil)
            // Reconnection: if CallKit session is still active, just re-send audio/start
            if self.activeCall != nil && self.audioReceiver.isRunning {
                print("[CallManager] reconnected with active call, re-sending audio/start")
                self.signaling.sendAudioStart()
            }
        }
    }

    func signalingDidDisconnect(_ client: SignalingClient, error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
            if let error = error, self.hasConnectedOnce {
                self.lastError = "连接断开: \(error.localizedDescription)"
            }
            // Don't touch audio here — let CallKit manage the session lifecycle.
            // If the call truly ended, the server will push a state update
            // which will trigger callKit.reportCallEnded() → didDeactivate.
        }
    }

    func signaling(_ client: SignalingClient, didReceiveCallState state: CallStatePush) {
        DispatchQueue.main.async {
            // While hanging up, ignore all call state until call is fully gone
            if self.isHangingUp {
                if state.active == nil {
                    self.isHangingUp = false
                    self.hangupWatchdog?.invalidate()
                    self.hangupWatchdog = nil
                }
                if let history = state.history { self.callHistory = history }
                if let module = state.module { self.moduleInfo = module }
                return
            }

            let wasActive = self.activeCall != nil

            if let serverActive = state.active {
                // 兼容 server 状态值：incoming / waiting / ringing 均视为来电振铃
                let isNewIncoming = serverActive.direction == "incoming"
                    && (serverActive.state == "incoming" || serverActive.state == "waiting" || serverActive.state == "ringing")
                    && self.activeCall?.id != serverActive.id

                self.activeCall = serverActive

                // 新通话开始时重置标志
                if self.activeCall?.id != serverActive.id {
                    self.callReportedConnected = false
                }

                // Report incoming call to CallKit — will trigger didActivate → startEngine
                if isNewIncoming {
                    self.signaling.keepAlive.stop()
                    self.callKit.reportIncomingCall(number: serverActive.number ?? "未知")
                }
            } else if !self.localInitiated {
                self.activeCall = nil
            }

            let isActive = self.activeCall != nil

            // Call ended
            if !isActive && wasActive {
                self.callKit.reportCallEnded(reason: .remoteEnded)
                self.stopCallTimer()
                self.callReportedConnected = false
                self.audioReceiver.stopRingback()
                self.audioReceiver.isMuted = false // 新通话默认不静音
                let generator = UIImpactFeedbackGenerator(style: .heavy)
                generator.impactOccurred()
            }

            // 对端接听：state=active → 报 CallKit connected + 开始计时 + 停回铃
            if let call = self.activeCall, call.state == "active" {
                if !self.callReportedConnected {
                    self.callReportedConnected = true
                    self.callKit.reportCallConnected(uuid: self.callKit.activeUUID ?? UUID())
                    self.audioReceiver.stopRingback()
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                    let generator = UIImpactFeedbackGenerator(style: .heavy)
                    generator.impactOccurred()
                }
                if self.callConnectTime == nil {
                    self.startCallTimer()
                    self.audioReceiver.callConnected()
                }
            }

            // 呼出振铃中：播放回铃音（嘟嘟嘟）
            if let call = self.activeCall, call.direction == "outgoing",
               call.state == "dialing" || call.state == "alerting" {
                self.audioReceiver.startRingback()
            } else {
                self.audioReceiver.stopRingback()
            }

            if let history = state.history { self.callHistory = history }
            if let module = state.module { self.moduleInfo = module }
        }
    }

    func signaling(_ client: SignalingClient, didReceiveError error: String, action: String?) {
        DispatchQueue.main.async {
            self.lastError = error
            // 拨号失败：服务器端无此通话，清理本地发起的呼叫，避免卡在"拨号中"
            if action == "dial", let call = self.activeCall, call.id?.hasPrefix("local-") == true {
                print("[CallManager] dial failed: \(error), cleaning up local call")
                self.localInitiated = false
                self.activeCall = nil
                self.stopCallTimer()
                self.callKit.reportCallEnded(reason: .failed)
            }
        }
    }

    func signalingDidReceiveIncomingCall(_ client: SignalingClient, call: CallInfo) {
        // Skip CallKit incoming call UI - conflicts with audio bridge
        print("[CallManager] incoming call from \(call.number ?? "unknown")")
    }

    // MARK: - Audio Bridge (deprecated — CallKit.didActivate/didDeactivate is the single entry point)
    // Kept as no-ops for any remaining call sites during transition.

    // MARK: - Call Timer

    private func startCallTimer() {
        callConnectTime = Date()
        callDurationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
            }
        }
    }

    private func stopCallTimer() {
        callDurationTimer?.invalidate()
        callDurationTimer = nil
        callConnectTime = nil
    }

    var callDurationString: String {
        guard let start = callConnectTime else { return "" }
        let elapsed = Int(Date().timeIntervalSince(start))
        let m = elapsed / 60
        let s = elapsed % 60
        return String(format: "%02d:%02d", m, s)
    }

    // stopAudioBridge removed — CallKit.didDeactivate handles this now.

    func getLocalIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0",
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let sockLen = socklen_t(addr.pointee.sa_len)
            getnameinfo(addr, sockLen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: hostname)
            break
        }
        return address
    }

    // MARK: - CallKit Sync
}

// MARK: - CallKitManagerDelegate

extension CallManager: CallKitManagerDelegate {
    func callKit(_ manager: CallKitManager, didAnswerCall uuid: UUID) {
        // User answered from CallKit UI — send answer to Mac
        // Don't start audio here — let didActivate audioSession handle it
        // to avoid stealing audio control from CallKit
        signaling.answer()
    }

    func callKit(_ manager: CallKitManager, didEndCall uuid: UUID) {
        // User ended from CallKit UI — send hangup to Mac
        signaling.hangup()
    }

    func callKit(_ manager: CallKitManager, didStartCall uuid: UUID, to number: String) {
        // CallKit confirmed outgoing call start
        // The actual dial was already sent in dial()
    }

    func callKit(_ manager: CallKitManager, didReceiveDTMF digit: String) {
        // 系统通话界面键盘按键 → 转发到 4G 模块（逐字符，服务器仅接受单字符）
        for d in digit {
            signaling.sendDTMF(digit: String(d))
        }
    }

    func callKit(_ manager: CallKitManager, didSetMuted muted: Bool) {
        // 系统通话界面静音按钮 → 同步本地音频与服务器
        DispatchQueue.main.async {
            self.audioReceiver.isMuted = muted
        }
        signaling.toggleMute(muted: muted)
    }

    func callKitDidActivateAudioSession(_ manager: CallKitManager) {
        // CallKit activated the .voiceChat session — start engine on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("[CallManager] CallKit activated session → starting engine")
            self.audioReceiver.startEngine()
            self.audioReceiver.callConnected()
            self.signaling.sendAudioStart()
        }
    }

    func callKitDidDeactivateAudioSession(_ manager: CallKitManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("[CallManager] CallKit deactivated session → stopping engine")
            self.audioReceiver.stopEngine()
            self.signaling.sendAudioStop()
            self.signaling.keepAlive.start()
        }
    }
}
