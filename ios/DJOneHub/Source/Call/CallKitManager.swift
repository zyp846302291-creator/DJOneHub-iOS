import Foundation
import CallKit
import AVFoundation

protocol CallKitManagerDelegate: AnyObject {
    func callKit(_ manager: CallKitManager, didAnswerCall uuid: UUID)
    func callKit(_ manager: CallKitManager, didEndCall uuid: UUID)
    func callKit(_ manager: CallKitManager, didStartCall uuid: UUID, to number: String)
    func callKit(_ manager: CallKitManager, didReceiveDTMF digit: String)
    func callKit(_ manager: CallKitManager, didSetMuted muted: Bool)
    func callKitDidActivateAudioSession(_ manager: CallKitManager)
    func callKitDidDeactivateAudioSession(_ manager: CallKitManager)
}

class CallKitManager: NSObject {
    weak var delegate: CallKitManagerDelegate?

    private let provider: CXProvider
    private let callController = CXCallController()
    private var activeCallUUID: UUID?
    private var callStartTime: Date?

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.phoneNumber]
        config.iconTemplateImageData = nil
        config.ringtoneSound = "default"

        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)

        // Listen for VoIP push incoming call notifications
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePushKitIncomingCall(_:)),
            name: .pushKitIncomingCall, object: nil
        )
    }

    @objc private func handlePushKitIncomingCall(_ notification: Notification) {
        let caller = notification.userInfo?["caller"] as? String ?? "未知号码"
        let uuidStr = notification.userInfo?["call_uuid"] as? String
        let uuid = uuidStr.flatMap(UUID.init) ?? UUID()
        print("[CallKit] push incoming call from \(caller), uuid=\(uuid)")
        reportIncomingCall(number: caller, uuid: uuid)
    }

    // MARK: - Report Call State (called from signaling)

    func reportIncomingCall(number: String, uuid: UUID = UUID()) {
        activeCallUUID = uuid
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .phoneNumber, value: number)
        update.hasVideo = false
        update.supportsGrouping = false
        update.supportsDTMF = true

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error = error {
                print("[CallKit] report incoming error: \(error)")
            } else {
                print("[CallKit] incoming call reported: \(number)")
            }
        }
    }

    func reportOutgoingCall(number: String, uuid: UUID = UUID()) {
        activeCallUUID = uuid
        callStartTime = Date()

        let handle = CXHandle(type: .phoneNumber, value: number)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = false

        let transaction = CXTransaction(action: action)
        callController.request(transaction) { error in
            if let error = error {
                print("[CallKit] start call error: \(error)")
            } else {
                print("[CallKit] outgoing call started: \(number)")
            }
        }

        // 不立即报 connected！等服务器确认对端接听（state=active）后再报
        // 这样 CallKit 会显示"呼叫中"而不是"通话中"
    }

    func reportCallConnected(uuid: UUID) {
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    func reportCallEnded(uuid: UUID, reason: CXCallEndedReason = .remoteEnded) {
        if activeCallUUID == uuid {
            activeCallUUID = nil
            callStartTime = nil
        }
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
    }

    func reportCallEnded(reason: CXCallEndedReason = .remoteEnded) {
        guard let uuid = activeCallUUID else { return }
        activeCallUUID = nil
        callStartTime = nil
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
    }

    func endCall() {
        guard let uuid = activeCallUUID else { return }
        let action = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: action)
        callController.request(transaction) { error in
            if let error = error {
                print("[CallKit] end call error: \(error)")
            }
        }
    }

    /// 通过CallKit接听来电——保持CallKit通话界面，不跳转到App
    func answerCall() {
        guard let uuid = activeCallUUID else { return }
        let action = CXAnswerCallAction(call: uuid)
        let transaction = CXTransaction(action: action)
        callController.request(transaction) { error in
            if let error = error {
                print("[CallKit] answer call error: \(error)")
            }
        }
    }

    var hasActiveCall: Bool {
        return activeCallUUID != nil
    }

    var activeUUID: UUID? {
        return activeCallUUID
    }
}

// MARK: - CXProviderDelegate

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        print("[CallKit] provider reset")
        activeCallUUID = nil
        callStartTime = nil
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        print("[CallKit] perform startCall: \(action.handle.value)")
        activeCallUUID = action.callUUID
        callStartTime = Date()
        delegate?.callKit(self, didStartCall: action.callUUID, to: action.handle.value)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        print("[CallKit] perform answer")
        delegate?.callKit(self, didAnswerCall: action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print("[CallKit] perform endCall")
        if activeCallUUID == action.callUUID {
            activeCallUUID = nil
            callStartTime = nil
        }
        delegate?.callKit(self, didEndCall: action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        print("[CallKit] setMuted: \(action.isMuted)")
        // 必须 fulfill，否则系统静音按钮状态会回滚（表现为"自动再次静音"）
        delegate?.callKit(self, didSetMuted: action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        print("[CallKit] DTMF: \(action.digits)")
        // 转发给 signaling（系统通话界面键盘 → 4G 模块）
        delegate?.callKit(self, didReceiveDTMF: action.digits)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        print("[CallKit] action timed out")
        action.fail()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("[CallKit] audio session activated by system — now safe to start engine")
        // CallKit already activated the session with the correct category.
        // We just need to tell AudioReceiver to start its engine.
        delegate?.callKitDidActivateAudioSession(self)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("[CallKit] audio session deactivated — stopping engine")
        delegate?.callKitDidDeactivateAudioSession(self)
    }
}
