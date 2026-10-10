import SwiftUI
import AVKit
import AVFoundation
import AudioToolbox

struct ContentView: View {
    @StateObject private var callManager: CallManager
    @StateObject private var api: APIClient
    @StateObject private var contactManager = ContactManager()
    @AppStorage("serverHost") private var serverHost = ""
    @AppStorage("serverPort") private var serverPort = 7576
    @AppStorage("appTheme") private var appTheme = "system" // system / light / dark
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedTab = 1 // Default to Calls tab
    @State private var dialNumber = ""
    @State private var showDTMF = false
    @State private var dtmfInput = ""
    @State private var showPasteButton = false
    @State private var smsUnread = 0

    init(serverHost: String = "", serverPort: Int = 7576) {
        let url = URL(string: "ws://\(serverHost):\(serverPort)/ws")!
        _callManager = StateObject(wrappedValue: CallManager(serverURL: url))
        _api = StateObject(wrappedValue: APIClient(host: serverHost, port: serverPort))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // 1. Overview
            NavigationStack {
                OverviewView(api: api)
                    .navigationTitle("概览")
            }
            .tabItem {
                Label("概览", systemImage: "chart.bar")
            }
            .tag(0)

            // 2. Dial
            NavigationStack {
                dialView
                    .navigationBarHidden(true)
            }
            .tabItem {
                Label("拨号", systemImage: "circle.grid.3x3")
            }
            .tag(1)

            // 3. History
            NavigationStack {
                historyView
                    .navigationTitle("通话记录")
            }
            .tabItem {
                Label("通话记录", systemImage: "clock.arrow.circlepath")
            }
            .badge(missedCallCount)
            .tag(2)

            // 4. SMS
            NavigationStack {
                SMSView(api: api, unreadSMS: $smsUnread)
                    .navigationTitle("短信")
            }
            .tabItem {
                Label("短信", systemImage: "message")
            }
            .badge(smsUnread)
            .tag(3)

            // 5. More
            NavigationStack {
                MoreView(api: api)
            }
            .tabItem {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .tag(4)
        }
        .preferredColorScheme(appTheme == "light" ? .light : appTheme == "dark" ? .dark : nil)
        .onAppear {
            callManager.connect()
            contactManager.loadContacts()
        }
        // 全局全屏通话界面：无论停留在哪个 tab，通话期间都覆盖显示
        .overlay {
            if callManager.activeCall != nil {
                fullScreenCallView
            }
        }
        // 连接状态横幅：断线/重连中时显示（通话中不遮挡通话界面）
        .overlay(alignment: .top) {
            if !callManager.isConnected && callManager.activeCall == nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(callManager.lastError?.isEmpty == false
                         ? "服务器连接断开，正在重连…"
                         : "正在连接服务器…")
                        .font(.system(size: 13))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial)
                .overlay(alignment: .bottom) { Divider() }
                .transition(.move(edge: .top))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: callManager.isConnected)
    }

    // MARK: - Full-Screen Call Overlay

    private var fullScreenCallView: some View {
        activeCallView
            .preferredColorScheme(.dark) // 通话界面恒深色，状态栏保持白色
    }

    // MARK: - Dial View

    private var dialView: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                statusBar

                // Idle: number bar + dial pad (通话界面由全屏覆盖层接管)
                numberBar

                Spacer()

                nativeDialPad

                Spacer()
                    .frame(height: 44)
            }
        }
    }

    // MARK: - Active Call View (iOS native call screen style)

    private var activeCallView: some View {
        let call = callManager.activeCall!
        let state = call.state ?? ""
        let isIncoming = state == "incoming" || state == "waiting"
        let displayName = contactManager.name(for: call.number) ?? formatNumber(call.number ?? "")

        return ZStack {
            // 原生通话背景：深灰渐变（壁纸暗化效果）
            LinearGradient(
                colors: [
                    Color(white: 0.26),
                    Color(white: 0.21),
                    Color(white: 0.17)
                ],
                startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 48)

                // 顶部：第一行时长/状态，第二行联系人名（对齐原生）
                if showDTMF && !isIncoming {
                    dtmfNumberDisplay
                } else {
                    VStack(spacing: 14) {
                        // 4G 模块信号指示（差异化点）
                        if let dbm = callManager.moduleInfo?.signal_dbm {
                            HStack(spacing: 5) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 10))
                                Text("\(dbm) dBm")
                                    .font(.system(size: 11, weight: .medium))
                                    .monospacedDigit()
                            }
                            .foregroundColor(.white.opacity(0.55))
                        }

                        Text(callManager.callDurationString.isEmpty
                             ? callStateText(state)
                             : callManager.callDurationString)
                            .font(.system(size: 32, weight: .regular))
                            .foregroundColor(.white.opacity(0.85))
                            .monospacedDigit()

                        Text(displayName)
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, 40)
                    }
                }

                Spacer()

                // 中部：来电显示头像；键盘展开显示 DTMF 键盘
                if showDTMF && !isIncoming {
                    dtmfKeyboardPad
                } else if isIncoming {
                    contactAvatar(initial: String(displayName.prefix(1)),
                                  imageData: contactManager.imageData(for: call.number))
                }

                Spacer()

                // 底部按钮区（对齐原生 3×2 网格）
                if isIncoming {
                    // 来电：拒接 / 接听（原生实心按钮）
                    HStack(spacing: 100) {
                        roundCallButton(icon: "phone.down.fill", color: .red, size: 74) {
                            callManager.reject()
                        }
                        roundCallButton(icon: "phone.fill", color: .green, size: 74) {
                            callManager.answer()
                        }
                    }
                } else {
                    // 通话/拨号中：上排功能键 + 红色结束居中
                    VStack(spacing: 36) {
                        HStack(spacing: 44) {
                            glassCallButton(icon: "speaker.wave.2.fill",
                                            label: callManager.audioReceiver.isSpeakerOn ? "扬声器" : "免提",
                                            isActive: callManager.audioReceiver.isSpeakerOn) {
                                callManager.audioReceiver.toggleSpeaker()
                            }
                            glassCallButton(icon: "mic.slash.fill", label: "静音",
                                            isActive: callManager.audioReceiver.isMuted) {
                                callManager.toggleMute(muted: !callManager.audioReceiver.isMuted)
                            }
                            glassCallButton(icon: "circle.grid.3x3.fill", label: "键盘",
                                            isActive: showDTMF) {
                                withAnimation(.easeInOut(duration: 0.2)) { showDTMF.toggle() }
                            }
                        }

                        HStack(spacing: 44) {
                            Spacer()
                            glassEndButton {
                                callManager.hangup()
                            }
                            Spacer()
                        }
                    }
                }

                Spacer()
                    .frame(height: 44)
            }
        }
    }

    // MARK: - Native Call UI Components

    /// 联系人头像：有真实头像显示图片，否则首字母圆形占位
    private func contactAvatar(initial: String, imageData: Data? = nil) -> some View {
        if let imageData, let uiImage = UIImage(data: imageData) {
            return AnyView(
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 116, height: 116)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            )
        }
        return AnyView(
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.20)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 116, height: 116)
                Text(initial.uppercased())
                    .font(.system(size: 54, weight: .medium))
                    .foregroundColor(Color(white: 0.78))
            }
        )
    }

    /// 原生大圆按钮（挂断/接听/拒接）
    private func roundCallButton(icon: String, color: Color, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.38))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(color)
                .clipShape(Circle())
        }
    }

    // MARK: - Liquid Glass UI (iOS 26 style)

    /// 通话功能键（扬声器/静音/键盘）— Liquid Glass 玻璃质感
    private func glassCallButton(icon: String, label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(isActive ? Color.white.opacity(0.92) : Color.white.opacity(0.18))
                        .background(.ultraThinMaterial, in: Circle())
                    Circle()
                        .stroke(
                            LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.10), .clear],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1)
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(isActive ? .black : .white)
                }
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
            }
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.82))
        }
    }

    /// 红色结束键 — 玻璃质感
    private func glassEndButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.92))
                Circle()
                    .stroke(
                        LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.10), .clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(.white)
            }
            .frame(width: 74, height: 74)
            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        }
    }

    /// DTMF 键盘顶部的号码显示
    private var dtmfNumberDisplay: some View {
        VStack(spacing: 8) {
            Text(dtmfInput.isEmpty ? (callManager.activeCall?.number ?? "") : dtmfInput)
                .font(.system(size: 34, weight: .light, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("键盘")
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.60))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    /// DTMF 键盘（Liquid Glass 玻璃数字键 + 隐藏键盘按钮）
    private var dtmfKeyboardPad: some View {
        VStack(spacing: 16) {
            let keys = ["1","2","3","4","5","6","7","8","9","*","0","#"]
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22), count: 3), spacing: 22) {
                ForEach(keys, id: \.self) { key in
                    Button {
                        dtmfInput += key
                        callManager.sendDTMF(digit: key)
                        playDialTone(for: key)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.16))
                                .background(.ultraThinMaterial, in: Circle())
                            Circle()
                                .stroke(
                                    LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.06), .clear],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    lineWidth: 1)
                            Text(key)
                                .font(.system(size: 28, weight: .light))
                                // 星号字形视觉补偿
                                .scaleEffect(key == "*" ? 2.0 : 1)
                                .foregroundColor(.white)
                        }
                        .frame(width: 70, height: 70)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    }
                }
            }
            .padding(.horizontal, 40)

            Button {
                dtmfInput = ""
                withAnimation(.easeInOut(duration: 0.2)) { showDTMF = false }
            } label: {
                Text("隐藏键盘")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 24)
                    .background(Color.white.opacity(0.16), in: Capsule())
            }
        }
    }

    // MARK: - Audio Route Picker (system, shows AirPods/Speaker/Earpiece)

    private struct AudioRoutePickerButton: UIViewRepresentable {
        func makeUIView(context: Context) -> AVRoutePickerView {
            let picker = AVRoutePickerView()
            picker.activeTintColor = .systemBlue
            picker.prioritizesVideoDevices = false
            return picker
        }
        func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
    }

    // MARK: - Number Bar

    private var numberBar: some View {
        HStack(spacing: 0) {
            // Paste button — only visible after long press
            if showPasteButton {
                Button {
                    if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                        let digits = pasted.filter { $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }
                        dialNumber += digits
                    }
                    showPasteButton = false
                } label: {
                    Text("粘贴")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.appPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.appFill.opacity(0.6))
                        .cornerRadius(8)
                }
                .padding(.leading, 16)
            }

            // Number display — centered
            Text(dialNumber.isEmpty ? "\u{00A0}" : formatNumber(dialNumber))
                .font(.system(size: dialNumber.count > 14 ? 24 : 34, weight: .light))
                .foregroundColor(.appPrimary)
                .frame(maxWidth: .infinity)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .multilineTextAlignment(.center)
                .onLongPressGesture(minimumDuration: 0.5) {
                    showPasteButton = true
                }
        }
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.15), value: showPasteButton)
    }

    // MARK: - Native Dial Pad (iOS style circles)

    private var nativeDialPad: some View {
        let keys: [(num: String, letters: String)] = [
            ("1", ""), ("2", "A B C"), ("3", "D E F"),
            ("4", "G H I"), ("5", "J K L"), ("6", "M N O"),
            ("7", "P Q R S"), ("8", "T U V"), ("9", "W X Y Z"),
            ("*", ""), ("0", "+"), ("#", "")
        ]

        return VStack(spacing: 24) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 30) {
                    ForEach(0..<3, id: \.self) { col in
                        let idx = row * 3 + col
                        let key = keys[idx]
                        nativeDialButton(num: key.num, letters: key.letters)
                    }
                }
            }

            // Call button centered — position locked
            HStack(spacing: 0) {
                Spacer()

                Button {
                    callManager.dial(number: dialNumber)
                    dialNumber = ""
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                        .frame(width: 96, height: 96)
                        .background(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    Color(red: 0.34, green: 0.83, blue: 0.38),
                                    Color(red: 0.22, green: 0.72, blue: 0.28)
                                ]),
                                center: .top,
                                startRadius: 0,
                                endRadius: 50
                            )
                        )
                        .clipShape(Circle())
                        .shadow(color: Color(red: 0.29, green: 0.80, blue: 0.34).opacity(0.25), radius: 6, y: 2)
                }

                Spacer()
            }
            .overlay(alignment: .trailing) {
                if !dialNumber.isEmpty {
                    Button {
                        dialNumber.removeLast()
                        AudioServicesPlaySystemSound(1212) // dtmf_clear
                    } label: {
                        ZStack {
                            Circle()
                                .fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.55))
                                .background(.ultraThinMaterial, in: Circle())
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        colors: colorScheme == .dark
                                            ? [Color.white.opacity(0.45), Color.white.opacity(0.06), .clear]
                                            : [Color.white.opacity(0.95), Color.white.opacity(0.35), .clear],
                                        startPoint: .topLeading, endPoint: .bottomTrailing),
                                    lineWidth: 1)
                            Image(systemName: "delete.left")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(colorScheme == .dark ? .white : .black)
                        }
                        .frame(width: 44, height: 44)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.05), radius: 4, y: 2)
                    }
                    .padding(.trailing, 30)
                }
            }
        }
    }


    /// 播放系统 DTMF 拨号按键音（与原生电话键盘一致：数字 1201-1209 / 0 1200 / * 1210 / # 1211 / 删除 1212）
    private func playDialTone(for digit: String) {
        var soundID: SystemSoundID
        switch digit {
        case "*": soundID = 1210
        case "#": soundID = 1211
        default:
            if let n = Int(digit), (0...9).contains(n) {
                soundID = SystemSoundID(1200 + n)
            } else {
                return
            }
        }
        AudioServicesPlaySystemSound(soundID)
    }

    private func nativeDialButton(num: String, letters: String) -> some View {
        Button {
            dialNumber += num
            playDialTone(for: num)
        } label: {
            ZStack {
                // Liquid Glass 按键（浅色/深色自适应）
                Circle()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.55))
                    .background(.ultraThinMaterial, in: Circle())
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [Color.white.opacity(0.45), Color.white.opacity(0.06), .clear]
                                : [Color.white.opacity(0.95), Color.white.opacity(0.35), .clear],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)

                VStack(spacing: 2) {
                    Text(num)
                        .font(.system(size: 40, weight: .light))
                        .frame(height: 44) // 数字行固定高度，保证 1/2/3 等所有键的数字上对齐
                        // 星号字形本身偏小（约 # 的 60%），仅渲染放大做视觉补偿；字号保持与 # 一致避免行高偏移
                        .scaleEffect(num == "*" ? 2.15 : 1)
                        .offset(y: num == "*" ? 16 : 0)
                        .foregroundColor(colorScheme == .dark ? .white : .black)

                    // 字母行固定占位（空键用空格），保证所有键的字母行在同一高度
                    Text(letters.isEmpty ? " " : letters)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(colorScheme == .dark ? Color.white.opacity(0.85) : Color.black.opacity(0.45))
                        .tracking(1.6)
                        .frame(height: 13)
                }
            }
            .frame(width: 90, height: 90)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.05), radius: 5, y: 2)
        }
        .buttonStyle(DialButtonStyle())
        .frame(width: 90, height: 90)
        // 长按 0 键输入国际号码前缀 +（原生行为）
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    if num == "0" {
                        dialNumber += "+"
                        AudioServicesPlaySystemSound(1200) // dtmf_0
                        let generator = UIImpactFeedbackGenerator(style: .light)
                        generator.impactOccurred()
                    }
                }
        )
    }

    // MARK: - History View

    /// 未接来电数（tab 角标）
    private var missedCallCount: Int {
        callManager.callHistory.filter { $0.missed == true }.count
    }

    private var historyView: some View {
        List {
            if callManager.callHistory.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.appSecondary)
                        Text("暂无通话记录")
                            .font(.system(size: 15))
                            .foregroundColor(.appSecondary)
                    }
                    .padding(.vertical, 60)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(callManager.callHistory.prefix(50), id: \.id) { call in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(callIconColor(call))
                            .frame(width: 32, height: 32)
                            .overlay(
                                Image(systemName: callIconName(call))
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(contactManager.name(for: call.number) ?? formatNumber(call.number ?? "未知"))
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.appPrimary)
                            Text(callDirectionText(call))
                                .font(.system(size: 12))
                                .foregroundColor(.appSecondary)
                        }

                        Spacer()

                        Button {
                            callManager.dial(number: call.number ?? "")
                            selectedTab = 1
                        } label: {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.blue)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { indexSet in
                    // 滑动删除：先取要删的 id，再逐条删除（本地 + 服务器）
                    let ids = indexSet.map { callManager.callHistory[$0].id }
                    for id in ids {
                        callManager.removeHistory(id: id)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .toolbar {
            if !callManager.callHistory.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") {
                        callManager.clearHistory()
                    }
                    .font(.system(size: 14))
                }
            }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(callManager.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(callManager.moduleInfo?.operator_name ?? (callManager.isConnected ? "已连接" : "连接中…"))
                    .font(.system(size: 13))
                    .foregroundColor(.appSecondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private func callButton(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(.white)
                .frame(width: 64, height: 64)
                .background(color)
                .clipShape(Circle())
        }
    }

    private func formatNumber(_ n: String) -> String {
        let clean = n.replacingOccurrences(of: " ", with: "")
        if clean.count == 11, clean.hasPrefix("1") {
            let a = clean.index(clean.startIndex, offsetBy: 3)
            let b = clean.index(clean.startIndex, offsetBy: 7)
            return "\(clean[..<a]) \(clean[a..<b]) \(clean[b...])"
        }
        return n
    }

    private func callStateText(_ state: String) -> String {
        switch state {
        case "incoming": return "来电"
        case "waiting": return "等待"
        case "dialing": return "拨号中"
        case "alerting": return "振铃中"
        case "active": return "通话中"
        case "held": return "保持中"
        default: return state
        }
    }

    private func callIconColor(_ call: CallInfo) -> Color {
        if call.missed == true { return .red }
        return call.direction == "outgoing" ? .blue : .green
    }

    private func callIconName(_ call: CallInfo) -> String {
        if call.missed == true { return "phone.down.fill" }
        return call.direction == "outgoing" ? "arrow.up.right" : "arrow.down.left"
    }

    private func callDirectionText(_ call: CallInfo) -> String {
        if call.missed == true { return "未接" }
        return call.direction == "outgoing" ? "呼出" : "呼入"
    }
}

// MARK: - Corner Radius Extension

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect,
                                byRoundingCorners: corners,
                                cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

// MARK: - Dial Button Style (press effect)

struct DialButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}