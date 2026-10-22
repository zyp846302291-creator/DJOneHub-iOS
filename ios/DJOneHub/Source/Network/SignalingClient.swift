import Foundation
import UIKit

// MARK: - Signal Message (matches Mac proxy signaling.go)

struct SignalMessage: Codable {
    let type: String
    let payload: Data?

    enum CodingKeys: String, CodingKey {
        case type, payload
    }
}

struct CallStatePush: Codable {
    let active: CallInfo?
    let history: [CallInfo]?
    let audio: AudioState?
    let module: ModuleInfo?
}

struct CallInfo: Codable {
    let id: String?
    let direction: String?
    let state: String?
    let number: String?
    let started_at: String?
    let missed: Bool?
}

struct AudioState: Codable {
    let running: Bool?
}

struct ModuleInfo: Codable {
    let operator_name: String?
    let signal_dbm: Int?
    let network_mode: String?
    let sim_inserted: Bool?

    enum CodingKeys: String, CodingKey {
        case signal_dbm, network_mode, sim_inserted
        case operator_name = "operator"
    }
}

// MARK: - Signaling Client Protocol

protocol SignalingClientDelegate: AnyObject {
    func signalingDidConnect(_ client: SignalingClient)
    func signalingDidDisconnect(_ client: SignalingClient, error: Error?)
    func signaling(_ client: SignalingClient, didReceiveCallState state: CallStatePush)
    func signaling(_ client: SignalingClient, didReceiveError error: String, action: String?)
    func signalingDidReceiveIncomingCall(_ client: SignalingClient, call: CallInfo)
}

// MARK: - WebSocket Signaling Client

class SignalingClient: NSObject {
    weak var delegate: SignalingClientDelegate?

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var serverURL: URL
    private var isConnected = false
    private var reconnectTimer: Timer?
    private var reconnectInterval: TimeInterval = 2.0
    private var lastCallState: CallStatePush?
    // Background task to keep WebSocket alive
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    let keepAlive = BackgroundKeepAlive()

    var serverHost: String {
        return serverURL.host ?? ""
    }

    init(serverURL: URL) {
        self.serverURL = serverURL
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: .main)

        // Keep WebSocket alive in background
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    func connect() {
        disconnect()
        webSocket = session?.webSocketTask(with: serverURL)
        webSocket?.resume()
        receiveMessage()
    }

    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        isConnected = false
        keepAlive.stop()
        endBackgroundTask()
    }

    // MARK: - Background Task Management

    @objc private func appDidEnterBackground() {
        guard isConnected else { return }
        // Start background task to keep WebSocket alive for incoming calls
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "DJOneHubWebSocket") {
            // Expiration handler — end the task
            self.endBackgroundTask()
        }
        print("[Signaling] entered background, taskID: \(backgroundTaskID.rawValue)")
    }

    @objc private func appWillEnterForeground() {
        endBackgroundTask()
        // Reconnect if needed
        if !isConnected {
            connect()
        }
    }

    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    // MARK: - Send Commands

    func dial(number: String) {
        let payload = try? JSONEncoder().encode(["number": number])
        send(type: "dial", payload: payload)
    }

    func answer() {
        send(type: "answer", payload: nil)
    }

    func hangup() {
        send(type: "hangup", payload: nil)
    }

    func reject() {
        send(type: "reject", payload: nil)
    }

    func sendDTMF(digit: String) {
        let payload = try? JSONEncoder().encode(["digit": digit])
        send(type: "dtmf", payload: payload)
    }

    func toggleMute(muted: Bool) {
        let payload = try? JSONEncoder().encode(["muted": muted])
        send(type: "mute", payload: payload)
    }

    func sendAudioStart() {
        send(type: "audio/start", payload: nil)
    }

    func sendAudioStop() {
        send(type: "audio/stop", payload: nil)
    }

    /// 清空通话记录（id 为空则全部清除）
    func clearHistory(id: String? = nil) {
        var payload: Data?
        if let id {
            payload = try? JSONEncoder().encode(["id": id])
        }
        send(type: "history_clear", payload: payload)
    }

    /// 向 proxy 上报推送凭证（与 PushKitManager 注册 Worker 的同一对 device_id/secret）。
    /// 每次 WebSocket 连接成功后自动调用。
    func sendPushCredentials() {
        let d1 = UserDefaults.standard.string(forKey: "push_device_id")
        let d2 = UserDefaults.standard.string(forKey: "push_device_secret")
        guard let deviceID = d1, let secret = d2, !deviceID.isEmpty, !secret.isEmpty else { return }
        let payload = try? JSONEncoder().encode(["device_id": deviceID, "device_secret": secret])
        send(type: "push_credentials", payload: payload)
    }

    /// Send mic audio data (s16le PCM) as binary WebSocket frame
    func sendAudioData(_ data: Data) {
        guard isConnected else { return }
        webSocket?.send(.data(data)) { error in
            if let error = error {
                print("[Signaling] audio send error: \(error)")
            }
        }
    }

    // MARK: - Private

    private func send(type: String, payload: Data?) {
        var msg: [String: Any] = ["type": type]
        if let payload = payload {
            msg["payload"] = try? JSONSerialization.jsonObject(with: payload)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let string = String(data: data, encoding: .utf8) else { return }

        webSocket?.send(.string(string)) { error in
            if let error = error {
                print("[Signaling] send error: \(error)")
            }
        }
    }

    var onAudioFrame: ((Data) -> Void)?

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    // Binary message = audio frame from Mac
                    if data.count > 8 {
                        self.onAudioFrame?(data)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()
            case .failure(let error):
                print("[Signaling] receive error: \(error)")
                self.handleDisconnect(error: error)
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        let payloadData = json["payload"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }

        switch type {
        case "call_state":
            if let payloadData = payloadData,
               let state = try? JSONDecoder().decode(CallStatePush.self, from: payloadData) {
                lastCallState = state

                // Detect incoming call（兼容 server 状态值：incoming / waiting / ringing）
                if let active = state.active,
                   active.direction == "incoming",
                   (active.state == "incoming" || active.state == "waiting" || active.state == "ringing") {
                    delegate?.signalingDidReceiveIncomingCall(self, call: active)
                }

                delegate?.signaling(self, didReceiveCallState: state)
            }

        case "api_response":
            // API response from DJOneHub - already handled via call_state push
            break

        case "error":
            if let payloadData = payloadData,
               let errorDict = try? JSONSerialization.jsonObject(with: payloadData) as? [String: String],
               let detail = errorDict["error"] {
                delegate?.signaling(self, didReceiveError: detail, action: errorDict["action"])
            }

        case "pong", "audio/started", "audio/stopped":
            // Acknowledged, no action needed
            break

        default:
            print("[Signaling] unknown message type: \(type)")
        }
    }

    private func handleDisconnect(error: Error?) {
        // 无论之前是否连接成功（isConnected），断开都要安排重连：
        // 首次连接失败时 isConnected 仍为 false，旧逻辑会直接 return，
        // 导致 Mac 不在线时 App 停留后台永不重试。
        if isConnected {
            isConnected = false
        }
        // Do NOT stop keepAlive here — keep app alive in background so reconnect works
        delegate?.signalingDidDisconnect(self, error: error)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectInterval, repeats: false) { [weak self] _ in
            print("[Signaling] reconnecting...")
            self?.connect()
        }
    }
}

extension SignalingClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        isConnected = true
        reconnectInterval = 2.0
        keepAlive.start()
        print("[Signaling] connected to \(serverURL)")
        delegate?.signalingDidConnect(self)
        // 连接建立后把推送凭证发给 proxy：Mac 侧收到来电且 iPhone 不在线时，
        // proxy 用它触发 Cloudflare Worker → APNs VoIP push。
        sendPushCredentials()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        handleDisconnect(error: nil)
    }
}
