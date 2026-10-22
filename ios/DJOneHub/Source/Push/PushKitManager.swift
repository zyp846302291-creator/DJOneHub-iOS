import Foundation
import PushKit
import UIKit

/// Manages PushKit VoIP token registration and relay registration.
/// When a VoIP push arrives, it reports the incoming call to CallKit
/// SYNCHRONOUSLY before calling the PushKit completion handler
/// (Apple requirement — otherwise iOS terminates the app).
class PushKitManager: NSObject, ObservableObject, PKPushRegistryDelegate {
    static let shared = PushKitManager()

    private(set) var voipToken: String?
    private(set) var isRegistered = false

    /// Relay URL (Cloudflare Worker)
    @Published var relayURL: String = ""

    /// 设备注册用的 CallKit 上报句柄。
    /// 由 App 启动时注入（CallKitManager 必须在 VoIP push 到达前就绪）。
    var callKitReporter: ((String, UUID) -> Void)?

    /// 防止重复创建 PKPushRegistry（onAppear + onChange 双触发场景）
    private var registryStarted = false
    private var lastRelayURL: String = ""

    /// Device identity for relay auth
    private var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "push_device_id") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "push_device_id")
        return id
    }
    private var deviceSecret: String {
        if let secret = UserDefaults.standard.string(forKey: "push_device_secret") { return secret }
        let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(secret, forKey: "push_device_secret")
        return secret
    }

    func start(relayURL: String) {
        self.relayURL = relayURL
        // relayURL 变化时需要重新注册（上报新地址），否则去重跳过
        if registryStarted && relayURL == lastRelayURL { return }
        registryStarted = true
        lastRelayURL = relayURL
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        print("[PushKit] starting, relay=\(relayURL)")
    }

    // MARK: - PKPushRegistryDelegate

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        voipToken = token
        print("[PushKit] VoIP token: \(token.prefix(16))...")
        registerWithRelay()
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        voipToken = nil
        isRegistered = false
        print("[PushKit] token invalidated")
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        print("[PushKit] received VoIP push: \(payload.dictionaryPayload)")
        // Apple 规范：必须在 completion 之前同步上报 CallKit，
        // 否则系统会终止 App（且审核必拒）。
        let (caller, callUUID) = parseIncomingPayload(payload)
        if let reporter = callKitReporter {
            // 同步路径：CallKitManager.reportIncomingCall 内部发起
            // reportNewIncomingCall 调用后立即返回（系统异步回调 completion），
            // 满足"completion 前已上报"的要求。
            reporter(caller, callUUID)
        } else {
            // 兜底：reporter 尚未注入（App 冷启动极端时序），仍需上报，
            // 直接通知 CallKitManager 兜底处理（同步调用链）。
            NotificationCenter.default.post(
                name: .pushKitIncomingCall,
                object: nil,
                userInfo: ["caller": caller, "call_uuid": callUUID.uuidString]
            )
        }
        completion()
    }

    /// 解析推送 payload：兼容 number / caller_name / caller 多种字段名
    /// （proxy 旧协议用 caller，Worker 新协议用 number + caller_name）。
    private func parseIncomingPayload(_ payload: PKPushPayload) -> (String, UUID) {
        let dict = payload.dictionaryPayload
        let number = dict["number"] as? String
        let callerName = dict["caller_name"] as? String
        let caller = dict["caller"] as? String
        // 展示优先级：来电号码 > 联系人名 > caller 旧字段 > 未知
        let display = number ?? callerName ?? caller ?? "未知号码"
        let uuidStr = dict["call_uuid"] as? String ?? dict["uuid"] as? String
        let callUUID = uuidStr.flatMap(UUID.init) ?? UUID()
        return (display, callUUID)
    }

    // MARK: - Register with Cloudflare Relay

    func registerWithRelay() {
        guard !relayURL.isEmpty, let token = voipToken else {
            print("[PushKit] skip register: relayURL or token missing")
            return
        }

        guard let base = URL(string: relayURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            print("[PushKit] invalid relay URL: \(relayURL)")
            return
        }
        // 容错：去掉尾部斜杠再拼接路径
        var baseStr = base.absoluteString
        while baseStr.hasSuffix("/") { baseStr.removeLast() }
        guard let url = URL(string: baseStr + "/v1/devices/register") else {
            print("[PushKit] cannot build register URL from \(relayURL)")
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "device_id": deviceID,
            "device_secret": deviceSecret,
            "voip_token": token,
            "alert_token": "",
            "watch_voip_token": "",
            "live_activity_push_to_start_token": "",
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.djonehub.remote",
            "environment": Self.pushEnvironment,
            "media_transport": "legacy_pcm"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("[PushKit] register failed: \(error)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                self?.isRegistered = true
                print("[PushKit] registered with relay OK")
            } else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                print("[PushKit] register failed: HTTP \(status) \(body)")
            }
        }.resume()
    }

    /// 推送环境自动检测：模拟器/开发构建走 sandbox，TestFlight/App Store 走 production。
    /// 依据：App Store/TestFlight 分发 receipt 缺失 "beta-receipts" 之外的开发标识。
    private static var pushEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        // Xcode 直接安装的构建 receipt 落在 sandboxReceipt；TestFlight/App Store 为 production receipt。
        if let receiptURL = Bundle.main.appStoreReceiptURL,
           receiptURL.lastPathComponent == "sandboxReceipt" {
            return "sandbox"
        }
        return "production"
        #endif
    }
}

extension Notification.Name {
    static let pushKitIncomingCall = Notification.Name("pushKitIncomingCall")
}
