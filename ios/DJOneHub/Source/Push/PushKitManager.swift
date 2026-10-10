import Foundation
import PushKit
import UIKit

/// Manages PushKit VoIP token registration and relay registration.
/// When a VoIP push arrives, it notifies CallManager to show incoming call UI.
class PushKitManager: NSObject, ObservableObject, PKPushRegistryDelegate {
    static let shared = PushKitManager()

    private(set) var voipToken: String?
    private(set) var isRegistered = false

    /// Relay URL (Cloudflare Worker)
    @Published var relayURL: String = ""

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
        handleIncomingPush(payload: payload)
        completion()
    }

    // MARK: - Register with Cloudflare Relay

    func registerWithRelay() {
        guard !relayURL.isEmpty, let token = voipToken else {
            print("[PushKit] skip register: relayURL or token missing")
            return
        }

        let url = URL(string: "\(relayURL)/v1/devices/register")!
        var request = URLRequest(url: url)
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
            "environment": "sandbox", // "production" for TestFlight/AppStore
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

    // MARK: - Handle Incoming Push

    private func handleIncomingPush(payload: PKPushPayload) {
        // Extract call info from payload
        let dict = payload.dictionaryPayload
        let callerNumber = dict["caller"] as? String ?? "未知号码"
        let callUUID = dict["call_uuid"] as? String ?? UUID().uuidString

        print("[PushKit] incoming call from \(callerNumber), uuid=\(callUUID)")

        // Notify CallManager to report incoming call via CallKit
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .pushKitIncomingCall,
                object: nil,
                userInfo: [
                    "caller": callerNumber,
                    "call_uuid": callUUID
                ]
            )
        }
    }
}

extension Notification.Name {
    static let pushKitIncomingCall = Notification.Name("pushKitIncomingCall")
}