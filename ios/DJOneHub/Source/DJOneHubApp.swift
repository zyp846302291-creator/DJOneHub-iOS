import SwiftUI
import PushKit

@main
struct DJOneHubApp: App {
    @AppStorage("serverHost") private var serverHost = "100.100.221.117"
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