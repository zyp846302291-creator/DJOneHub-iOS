import SwiftUI
import PushKit

@main
struct DJOneHubApp: App {
    // 方向锁定：仅 iPhone Duo 允许旋转，其他 iPhone 竖屏锁定（iPad 不限）
    @UIApplicationDelegateAdaptor(OrientationLock.self) var orientationDelegate

    @AppStorage("serverHost") private var serverHost = "127.0.0.1"
    @AppStorage("serverPort") private var serverPort = 7576
    @AppStorage("pushRelayURL") private var pushRelayURL = ""

    @StateObject private var pushManager = PushKitManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView(serverHost: serverHost, serverPort: serverPort)
                .onAppear {
                    if !pushRelayURL.isEmpty {
                        pushManager.start(relayURL: pushRelayURL)
                    }
                }
                .onChange(of: pushRelayURL) { newURL in
                    if !newURL.isEmpty {
                        pushManager.start(relayURL: newURL)
                    }
                }
        }
    }
}