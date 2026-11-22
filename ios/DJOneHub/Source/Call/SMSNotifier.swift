import Foundation
import UserNotifications

/// 新短信到达时弹本地通知。
///
/// 由 ContentView（App 级常驻）持有，而不是放在 SMSView 里：
/// SMSView 只在用户打开短信 tab 时才存在，而「人不在短信页」恰恰是最需要提醒的场景。
///
/// 局限：这是本地通知，不是 APNs 远程推送。App 被划掉或 WebSocket 断开时收不到
/// （免费 Apple ID 签不了推送权限）。它只覆盖 App 在前台或刚退到后台、连接还在的情况。
final class SMSNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = SMSNotifier()

    /// 用户是否已回答过通知权限弹窗（无论同意还是拒绝）
    private var permissionAsked: Bool {
        get { UserDefaults.standard.bool(forKey: "smsNotificationPermissionAsked") }
        set { UserDefaults.standard.set(newValue, forKey: "smsNotificationPermissionAsked") }
    }

    /// 已弹过通知的最新短信时间戳，用于代理重连后重推的去重
    private var lastNotifiedTimestamp: String?

    private override init() {
        super.init()
        // 必须在 App 启动早期设置，否则前台收到的通知不会被展示
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermissionIfNeeded() {
        // 只问一次：拒绝后系统不再弹窗，反复请求没有意义
        guard !permissionAsked else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            // 等系统有了结果再标记，避免弹窗被打断后再也不请求
            self?.permissionAsked = true
            if let error = error {
                print("[SMSNotifier] permission error: \(error)")
            } else {
                print("[SMSNotifier] permission granted: \(granted)")
            }
        }
    }

    /// 处理代理推来的新短信。返回是否真的弹了通知。
    @discardableResult
    func notify(messages: [SMSMessage]) -> Bool {
        guard let newest = messages.max(by: { $0.timestamp < $1.timestamp }) else { return false }

        // 代理断线重连后可能重推同一条短信，按时间戳去重
        if let last = lastNotifiedTimestamp, last >= newest.timestamp { return false }
        lastNotifiedTimestamp = newest.timestamp

        let content = UNMutableNotificationContent()
        if messages.count == 1 {
            content.title = "短信 · \(newest.sender)"
            content.body = newest.content
        } else {
            content.title = "短信 · \(messages.count) 条新消息"
            content.body = messages.map { "\($0.sender): \($0.content)" }.joined(separator: "\n")
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "sms-\(newest.timestamp)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[SMSNotifier] notify error: \(error)")
            }
        }
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// App 在前台时系统默认不展示通知。用户停留在别的 tab（拨号、概览）时需要看得到，
    /// 所以前台也展示成横幅。
    /// 已知不足：用户正开着短信页时同样会弹一条横幅（页面本身已能看到这条短信），略冗余。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
