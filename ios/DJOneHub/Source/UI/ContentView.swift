import SwiftUI
import AVKit
import AVFoundation
import AudioToolbox

/// iOS 27+ 侧边栏 tab（官方 iPhone Duo 推荐形态）；低版本空操作
struct SidebarTabModifier: ViewModifier {
    var sidebar: Bool
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.defaultTabBarPlacement(sidebar ? .sidebar : .automatic)
        } else {
            content
        }
    }
}

struct ContentView: View {
    @StateObject private var callManager: CallManager
    @StateObject private var api: APIClient
    @StateObject private var contactManager = ContactManager()
    @AppStorage("serverHost") private var serverHost = "100.100.221.117"
    @AppStorage("serverPort") private var serverPort = 7576
    @AppStorage("appTheme") private var appTheme = "system" // system / light / dark
    @AppStorage("demoMode") private var demoMode = false
    @Environment(\.colorScheme) private var colorScheme
    // 官方推荐：用 size class 判定形态（Apple Tech Talks "Preparing your app for iPhone Duo"）。
    // 内屏（展开）= horizontalSizeClass .regular；外屏（折叠）= .compact。
    // 不要用 UIScreen / 方向 / 宽度阈值判定。
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedTab = 1 // Default to Calls tab
    @State private var dialNumber = ""
    @State private var showDTMF = false
    @State private var dtmfInput = ""
    @State private var smsUnread = 0

    init(serverHost: String = "100.100.221.117", serverPort: Int = 7576) {
        // 容错：host/port 异常时回退默认地址，避免强解包崩溃
        let safeHost = serverHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = safeHost.isEmpty ? "100.100.221.117" : safeHost
        let port = (1...65535).contains(serverPort) ? serverPort : 7576
        let urlString = "ws://\(host):\(port)/ws"
        let url = URL(string: urlString) ?? URL(string: "ws://100.100.221.117:7576/ws")!
        _callManager = StateObject(wrappedValue: CallManager(serverURL: url))
        _api = StateObject(wrappedValue: APIClient(host: host, port: port))
    }

    var body: some View {
        // 展开形态（horizontalSizeClass == .regular，即内屏）：
        // 拨号页左栏已含"通话/联系人"，总 tab 移除"通话记录"避免重复
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

            // 3. History（仅外屏/紧凑形态装入；内屏由拨号页左栏承接）
            if !isWideFormat {
                NavigationStack {
                    historyView
                        .navigationTitle("通话记录")
                }
                .tabItem {
                    // 原生电话 App「最近通话」同款时钟图标
                    Label("通话记录", systemImage: "clock")
                }
                .badge(missedCallCount)
                .tag(2)
            }

            // 4. SMS
            NavigationStack {
                SMSView(api: api, unreadSMS: $smsUnread)
                    .navigationTitle("信息")
            }
            .tabItem {
                Label("信息", systemImage: "message")
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
        .modifier(SidebarTabModifier(sidebar: isWideFormat))
        .preferredColorScheme(appTheme == "light" ? .light : appTheme == "dark" ? .dark : nil)
        .onAppear {
            callManager.demoMode = demoMode
            api.demoMode = demoMode
            callManager.connect()
            contactManager.loadContacts()
        }
        // 全局全屏通话界面：无论停留在哪个 tab，通话期间都覆盖显示
        .overlay {
            if callManager.activeCall != nil {
                fullScreenCallView
            }
        }
        // 连接状态：仅通过号码栏指示点提示（绿色=已连接/红色=断开），
        // 不再显示顶部横幅
        .animation(.easeInOut(duration: 0.25), value: callManager.isConnected)
        .onChange(of: isWideFormat) { wide in
            // 折叠↔展开切换时：若停留在内屏已移除的通话记录 tab，弹回拨号页
            if wide && selectedTab == 2 {
                selectedTab = 1
            }
        }
    }

    /// 内屏（展开）判定：官方 size class 方式，环境变化自动驱动视图刷新
    private var isWideFormat: Bool {
        horizontalSizeClass == .regular
    }

    // MARK: - Full-Screen Call Overlay

    private var fullScreenCallView: some View {
        activeCallView
            .preferredColorScheme(.dark) // 通话界面恒深色，状态栏保持白色
    }

    // MARK: - Dial View

    private var dialView: some View {
        GeometryReader { geo in
            // 横竖屏判定仍用尺寸比（内屏不遵循方向锁定，官方建议用 size class
            // 做"布局形态"决策，但横竖键盘摆放仍需方向信息）
            let isLandscape = geo.size.width > geo.size.height

            ZStack {
                Color.appBackground.ignoresSafeArea()

                if isWideFormat {
                    // 内屏（horizontalSizeClass == .regular）：双栏——左 通话/联系人 + 右 拨号区
                    wideDialView(isLandscape: isLandscape)
                } else if isLandscape {
                    // 外屏横屏 / 常规 iPhone 横屏：号码下移贴键盘上方，键盘保持居中
                    landscapeDialView
                } else {
                    VStack(spacing: 0) {
                        // Idle: number bar + dial pad (通话界面由全屏覆盖层接管)
                        numberBar(topInset: geo.safeAreaInsets.top, availableWidth: geo.size.width)

                        // 拨号盘占满剩余空间
                        portraitDialPad
                    }
                }
            }
        }
    }

    // MARK: - Wide Format Dial（展开形态双栏：横竖共用，左 内容/选项卡 + 右 拨号）

    @State private var dialSideTab = 0  // 左栏内容切换：0=最近通话 1=联系人

    private func wideDialView(isLandscape: Bool) -> some View {
        GeometryReader { geo in
            let keySize = wideDialKeySize(available: geo.size, isLandscape: isLandscape)
            let dialBtnSize = min(84, max(60, keySize))
            // 底部间距按方向：竖版展开要避开底部 Home 条 + tab 栏，整体上移更多
            let bottomPad: CGFloat = isLandscape ? 10 : 90
            // 列表可视高度 = 总高 − 选项卡区（32 picker + 8 top + 10 bottom = 50）
            let listViewportH = geo.size.height - 50
            HStack(spacing: 0) {
                // 左栏：顶部选项卡 + 列表（内容不足一屏时垂直居中）
                VStack(spacing: 0) {
                    // 分段选项卡：贴近列表顶部（控制者与被控者不分离）
                    Picker("", selection: $dialSideTab) {
                        Text("最近通话").tag(0)
                        Text("联系人").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .overlay(alignment: .topLeading) {
                        // 原生样式未接红点角标（与系统 tab badge 同款小红点）
                        if missedCallCount > 0 {
                            Text("\(missedCallCount)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .frame(minWidth: 18)
                                .background(Capsule().fill(Color.red))
                                .offset(x: 104, y: -4)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                    // 列表区：与右栏第一行按键顶部对齐。
                    // 子项收窄：容器水平 padding 加大（卡片两侧留白更多，栏宽不变）
                    ScrollView(showsIndicators: false) {
                        Group {
                            if dialSideTab == 0 {
                                recentCallsPanel(limit: 20, showsTitle: false)
                            } else {
                                contactsPanel(compactStyle: true)
                            }
                        }
                        .padding(.horizontal, 28)
                    }
                    .padding(.top, isLandscape ? 52 : 66)  // 竖版展开：往下再多 16pt
                }
                // 左栏宽度按方向：横屏 50%（列表空间充裕），竖版 42%（定稿）
                .frame(width: geo.size.width * (isLandscape ? 0.5 : 0.42))

                // 右栏：号码 → 键盘 → 绿色拨号（与竖版结构一致）
                VStack(spacing: 0) {
                    dialNumberDisplay(compact: true)
                        .padding(.top, isLandscape ? 36 : 12)
                        .padding(.bottom, 6)

                    Spacer(minLength: 12)

                    dialKeysGrid(keySize: keySize, vSpacing: 24, hSpacing: 36)

                    Spacer(minLength: 16)

                    callButtonRow(btnSize: dialBtnSize)
                        .padding(.bottom, bottomPad)
                }
                .frame(maxHeight: .infinity)
                // 左右不对称 padding：平衡整体两侧留白
                // （键盘居中导致右侧堆 60pt vs 左侧 28pt，把键盘往左推补偿）
                .padding(.leading, isLandscape ? 16 : 8)
                .padding(.trailing, isLandscape ? 16 : 44)
            }
            // 内屏顶部安全区补偿：状态栏悬空时 inset=0，内容会贴屏幕顶边
            .padding(.top, geo.safeAreaInsets.top == 0 ? 20 : 4)
        }
    }

    /// 展开形态键盘尺寸：高度约束为主，宽度兜底
    private func wideDialKeySize(available: CGSize, isLandscape: Bool) -> CGFloat {
        let topPad: CGFloat = isLandscape ? 40 : 48
        let byHeight = (available.height - topPad - 56 - 24 - 84 - 10 - 24) / 4 - 24
        let byWidth = (available.width * 0.58 - 2 * 36 - 24) / 3
        return min(88, max(48, min(byHeight, byWidth)))
    }

    // MARK: - Active Call View (iOS native call screen style)

    private var activeCallView: some View {
        GeometryReader { geo in
            // 折叠屏自适应：以短边为基准计算缩放（430pt = 常规 iPhone 宽度）。
            // 折叠外屏 ≈0.72~0.85，展开内屏/常规机 ≈1.0，超大屏封顶 1.15。
            let s = min(1.15, max(0.72, min(geo.size.width, geo.size.height) / 430))
            activeCallBody(scale: s, width: geo.size.width)
        }
    }

    private func activeCallBody(scale s: CGFloat, width: CGFloat) -> some View {
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
                    .frame(height: 48 * s)

                // 顶部：第一行时长/状态，第二行联系人名（对齐原生）
                if showDTMF && !isIncoming {
                    dtmfNumberDisplay(scale: s)
                } else {
                    VStack(spacing: 14 * s) {
                        // 4G 模块信号指示（差异化点）
                        if let dbm = callManager.moduleInfo?.signal_dbm {
                            HStack(spacing: 5 * s) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: max(9, 10 * s)))
                                Text("\(dbm) dBm")
                                    .font(.system(size: max(10, 11 * s), weight: .medium))
                                    .monospacedDigit()
                            }
                            .foregroundColor(.white.opacity(0.55))
                        }

                        Text(callManager.callDurationString.isEmpty
                             ? callStateText(state)
                             : callManager.callDurationString)
                            .font(.system(size: max(22, 32 * s), weight: .regular))
                            .foregroundColor(.white.opacity(0.85))
                            .monospacedDigit()

                        Text(displayName)
                            .font(.system(size: max(26, 38 * s), weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, 40 * s)
                    }
                }

                Spacer()

                // 中部：来电显示头像；键盘展开显示 DTMF 键盘
                if showDTMF && !isIncoming {
                    dtmfKeyboardPad(scale: s, width: width)
                } else if isIncoming {
                    contactAvatar(initial: String(displayName.prefix(1)),
                                  imageData: contactManager.imageData(for: call.number),
                                  scale: s)
                }

                Spacer()

                // 底部按钮区（对齐原生 3×2 网格）
                if isIncoming {
                    // 来电：拒接 / 接听（原生实心按钮）；间距随屏宽收紧，避免外屏溢出
                    HStack(spacing: min(100 * s, width * 0.3)) {
                        roundCallButton(icon: "phone.down.fill", color: .red, size: max(56, 74 * s)) {
                            callManager.reject()
                        }
                        roundCallButton(icon: "phone.fill", color: .green, size: max(56, 74 * s)) {
                            callManager.answer()
                        }
                    }
                } else {
                    // 通话/拨号中：上排功能键 + 红色结束居中；
                    // 功能键横向间距按剩余宽度收紧（外屏 320pt 时 3×64+2×44 会顶满溢出）
                    let btnSize = max(48, 64 * s)
                    let hSpace = min(44 * s, max(16, (width - btnSize * 3 - 32) / 2))
                    VStack(spacing: 36 * s) {
                        HStack(spacing: hSpace) {
                            glassCallButton(icon: "speaker.wave.2.fill",
                                            label: callManager.audioReceiver.isSpeakerOn ? "扬声器" : "免提",
                                            isActive: callManager.audioReceiver.isSpeakerOn,
                                            scale: s) {
                                callManager.audioReceiver.toggleSpeaker()
                            }
                            glassCallButton(icon: "mic.slash.fill", label: "静音",
                                            isActive: callManager.audioReceiver.isMuted,
                                            scale: s) {
                                callManager.toggleMute(muted: !callManager.audioReceiver.isMuted)
                            }
                            glassCallButton(icon: "circle.grid.3x3.fill", label: "键盘",
                                            isActive: showDTMF,
                                            scale: s) {
                                withAnimation(.easeInOut(duration: 0.2)) { showDTMF = !showDTMF }
                            }
                        }

                        HStack(spacing: 44) {
                            Spacer()
                            glassEndButton(scale: s) {
                                callManager.hangup()
                            }
                            Spacer()
                        }
                    }
                }

                Spacer()
                    .frame(height: 44 * s)
            }
        }
    }

    // MARK: - Native Call UI Components

    /// 联系人头像：有真实头像显示图片，否则首字母圆形占位
    private func contactAvatar(initial: String, imageData: Data? = nil, scale s: CGFloat = 1) -> some View {
        let size = max(72, 116 * s)
        if let imageData, let uiImage = UIImage(data: imageData) {
            return AnyView(
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            )
        }
        return AnyView(
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.20)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: size, height: size)
                Text(initial.uppercased())
                    .font(.system(size: max(30, 54 * s), weight: .medium))
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
    private func glassCallButton(icon: String, label: String, isActive: Bool, scale s: CGFloat = 1, action: @escaping () -> Void) -> some View {
        let size = max(48, 64 * s)
        return VStack(spacing: 10 * s) {
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
                        .font(.system(size: max(16, 22 * s), weight: .medium))
                        .foregroundColor(isActive ? .black : .white)
                }
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
            }
            Text(label)
                .font(.system(size: max(10, 12 * s), weight: .medium))
                .foregroundColor(.white.opacity(0.82))
        }
    }

    /// 红色结束键 — 玻璃质感
    private func glassEndButton(scale s: CGFloat = 1, action: @escaping () -> Void) -> some View {
        let size = max(56, 74 * s)
        return Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.92))
                Circle()
                    .stroke(
                        LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.10), .clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
                Image(systemName: "phone.down.fill")
                    .font(.system(size: max(20, 26 * s), weight: .medium))
                    .foregroundColor(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        }
    }

    /// DTMF 键盘顶部的号码显示
    private func dtmfNumberDisplay(scale s: CGFloat = 1) -> some View {
        VStack(spacing: 8 * s) {
            Text(dtmfInput.isEmpty ? (callManager.activeCall?.number ?? "") : dtmfInput)
                .font(.system(size: max(24, 34 * s), weight: .light, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("键盘")
                .font(.system(size: max(11, 13 * s)))
                .foregroundColor(Color(white: 0.60))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40 * s)
    }

    /// DTMF 键盘（Liquid Glass 玻璃数字键 + 隐藏键盘按钮）
    /// 键尺寸按可用宽度自适应：3 键 + 2 间距必须 < 屏宽 - 2×边距（外屏 320pt 场景）
    private func dtmfKeyboardPad(scale s: CGFloat = 1, width: CGFloat = 390) -> some View {
        let keySize = max(48, min(70 * s, (width - 80 - 44) / 3))
        let spacing = max(12, min(22 * s, (width - 80 - keySize * 3) / 2))
        return VStack(spacing: 16 * s) {
            let keys = ["1","2","3","4","5","6","7","8","9","*","0","#"]
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3), spacing: spacing) {
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
                                .font(.system(size: keySize * 0.4, weight: .light))
                                // 星号字形视觉补偿
                                .scaleEffect(key == "*" ? 2.0 : 1)
                                .foregroundColor(.white)
                        }
                        .frame(width: keySize, height: keySize)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    }
                }
            }
            .padding(.horizontal, 40 * s)

            Button {
                dtmfInput = ""
                withAnimation(.easeInOut(duration: 0.2)) { showDTMF = false }
            } label: {
                Text("隐藏键盘")
                    .font(.system(size: max(13, 15 * s)))
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

    // MARK: - Number Bar（竖屏顶部号码栏）

    private func numberBar(topInset: CGFloat, availableWidth: CGFloat = 390) -> some View {
        HStack(spacing: 0) {
            // 号码为空：运营商状态居中显示
            if dialNumber.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionDotColor)
                        .frame(width: 8, height: 8)
                    Text(connectionStatusText)
                        .font(.system(size: 13))
                        .foregroundColor(.appSecondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                // Number display — centered；字号按实际可用宽度自适应（420pt 外屏→40，375→36）。
                // 官方规范：禁止 UIScreen.main（双屏歧义），用局部宽度。
                // 长按 → 系统原生光标+粘贴菜单（contextMenu）
                let numFont = min(40, max(30, availableWidth * 0.095))
                dialNumberText(fontSize: dialNumber.count > 14 ? numFont * 0.72 : numFont)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 0)
        // 顶部安全区补偿：折叠屏竖屏顶部 inset 可能为 0（状态栏悬空不占位），补足状态栏高度
        .frame(height: 56)
        .padding(.top, max(0, 44 - topInset))
        .frame(maxWidth: .infinity)
    }

    // MARK: - Portrait Dial Pad (竖屏键盘：号码顶 / 弹性间距 / 键盘中 / 绿色按钮底)

    private var portraitDialPad: some View {
        GeometryReader { geo in
            let byWidth = geo.size.width * 0.19
            let btnSize = min(84, max(60, byWidth))
            let byHeight = (geo.size.height - 56 - 20 - 24 - btnSize - 10) / 4 - 24
            let keySize = min(80, max(52, min(byWidth, byHeight)))
            VStack(spacing: 0) {
                Spacer(minLength: 20)
                dialKeysGrid(keySize: keySize, vSpacing: 24)
                Spacer(minLength: 24)
                callButtonRow(btnSize: btnSize)
                Spacer(minLength: 10)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Landscape Dial (外屏/常规机横屏：号码下移贴键盘上方，键盘居中不动)

    private var landscapeDialView: some View {
        GeometryReader { geo in
            let keySize = min(84, max(40, (geo.size.height - 76) / 4 - 16))
            VStack(spacing: 0) {
                Spacer(minLength: 12)                       // 顶部弹性
                // 号码栏：下移到键盘正上方（不再贴顶），与键盘同宽居中
                dialNumberDisplay(compact: true)
                    .padding(.bottom, 14)
                dialKeysGrid(keySize: keySize, vSpacing: 16)
                    .padding(.top, 0)
                Spacer(minLength: 12)                       // 底部弹性
            }
            .frame(maxWidth: 640)                           // 常规横屏限宽，避免键盘飘太散
            .frame(maxWidth: .infinity)                     // 整体居中
            .overlay(alignment: .trailing) {
                // 绿色按钮列：顶部与键盘第二行（4 5 6）对齐偏上（用户目测微调 -30）
                callButtonColumn(keySize: keySize)
                    .padding(.trailing, 40)
                    .offset(y: 54 + keySize + 16 - 90)
            }
        }
    }

    /// 号码显示：长按弹系统样式「粘贴」菜单（contextMenu 原生渲染，
    /// 视觉与系统编辑菜单一致；纯 Text 永不聚焦不弹系统键盘）
    private func dialNumberText(fontSize: CGFloat) -> some View {
        Text(formatNumber(dialNumber))
            .font(.system(size: fontSize, weight: .light))
            .foregroundColor(.appPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(.center)
            .contextMenu {
                Button {
                    if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                        let digits = pasted.filter { $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }
                        dialNumber += digits
                    }
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                }
            }
    }

    /// 横屏用的号码显示（紧凑版，跟随键盘宽度居中）
    private func dialNumberDisplay(compact: Bool) -> some View {
        Group {
            if dialNumber.isEmpty {
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionDotColor)
                        .frame(width: 8, height: 8)
                    Text(connectionStatusText)
                        .font(.system(size: 13))
                        .foregroundColor(.appSecondary)
                }
            } else {
                dialNumberText(fontSize: dialNumber.count > 14 ? 26 : 34)
            }
        }
        .frame(maxWidth: .infinity)
        // 固定高度：空号状态行(约17pt)与号码(约40pt)高度不同会顶动键盘布局，
        // 恒定 40pt 保证输入时键盘纹丝不动
        .frame(height: 40)
    }

    /// 最近通话面板（limit 控制条数；showsTitle 控制标题显隐）
    private func recentCallsPanel(limit: Int = 5, showsTitle: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle {
                Text("最近通话")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.appSecondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 4)
            }

            let recents = callManager.callHistory.prefix(limit)
            if recents.isEmpty {
                Text("暂无通话记录")
                    .font(.system(size: 13))
                    .foregroundColor(.appSecondary.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                ForEach(Array(recents), id: \.id) { call in
                    Button {
                        dialNumber = call.number ?? ""
                    } label: {
                        HStack(spacing: 10) {
                            // 原生电话 SF Symbols（无底色小图标，同系统通话记录）
                            Image(systemName: recentCallIconName(call))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(callIconColor(call))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contactManager.name(for: call.number) ?? formatNumber(call.number ?? "未知"))
                                    .font(.system(size: 15))
                                    .foregroundColor(.appPrimary)
                                    .lineLimit(1)
                                Text("\(callDirectionText(call)) · \(call.started_at ?? "")")
                                    .font(.system(size: 12))
                                    .foregroundColor(.appSecondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color.appFill.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 拨号左栏最近通话图标：原生电话 SF Symbols
    private func recentCallIconName(_ call: CallInfo) -> String {
        if call.missed == true { return "phone.down.fill" }
        return call.direction == "outgoing" ? "phone.arrow.up.right.fill" : "phone.arrow.down.left.fill"
    }

    private func dialKeysGrid(keySize: CGFloat, vSpacing: CGFloat, hSpacing: CGFloat = 30) -> some View {
        let keys: [(num: String, letters: String)] = [
            ("1", ""), ("2", "A B C"), ("3", "D E F"),
            ("4", "G H I"), ("5", "J K L"), ("6", "M N O"),
            ("7", "P Q R S"), ("8", "T U V"), ("9", "W X Y Z"),
            ("*", ""), ("0", "+"), ("#", "")
        ]

        return VStack(spacing: vSpacing) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: hSpacing) {
                    ForEach(0..<3, id: \.self) { col in
                        let idx = row * 3 + col
                        let key = keys[idx]
                        nativeDialButton(num: key.num, letters: key.letters, size: keySize)
                    }
                }
            }
        }
    }

    // 竖屏：绿色按钮居中，删除键在右侧。
    // 删除键恒占位（空号时仅隐藏视觉），布局高度不变——键盘位置稳定不动
    private func callButtonRow(btnSize: CGFloat) -> some View {
        HStack(spacing: 0) {
            Spacer()

            dialGreenButton(size: btnSize)

            Spacer()
        }
        .frame(height: btnSize)
        .overlay(alignment: .trailing) {
            dialDeleteButton
                .padding(.trailing, 30)
                .opacity(dialNumber.isEmpty ? 0 : 1)
                .allowsHitTesting(!dialNumber.isEmpty)
        }
    }

    // 横屏：绿色按钮 + 删除键纵向排列（删除键恒占位，布局稳定）
    private func callButtonColumn(keySize: CGFloat) -> some View {
        VStack(spacing: 24) {
            dialGreenButton(size: min(84, max(60, keySize)))
            dialDeleteButton
                .opacity(dialNumber.isEmpty ? 0 : 1)
                .allowsHitTesting(!dialNumber.isEmpty)
        }
    }

    private func dialGreenButton(size: CGFloat) -> some View {
        Button {
            callManager.dial(number: dialNumber)
            dialNumber = ""
        } label: {
            Image(systemName: "phone.fill")
                .font(.system(size: size * 0.33))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.34, green: 0.83, blue: 0.38),
                            Color(red: 0.22, green: 0.72, blue: 0.28)
                        ]),
                        center: .top,
                        startRadius: 0,
                        endRadius: size * 0.52
                    )
                )
                .clipShape(Circle())
                .shadow(color: Color(red: 0.29, green: 0.80, blue: 0.34).opacity(0.25), radius: 6, y: 2)
        }
    }

    private var dialDeleteButton: some View {
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

    private func nativeDialButton(num: String, letters: String, size: CGFloat = 90) -> some View {
        // 字体随按键尺寸等比缩放：常规 90pt 键 → 40pt 数字/11pt 字母（原生比例），
        // 折叠外屏/横屏小键自动缩小，避免文字溢出圆形按键
        let numFont = max(20, size * 40 / 90)
        let letterFont = max(7, size * 11 / 90)
        return Button {
            dialNumber += num
            playDialTone(for: num)
            // 按键触感（原生电话键盘同款轻触反馈）
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
                        .font(.system(size: numFont, weight: .light))
                        .frame(height: numFont * 1.1) // 数字行固定高度（按字号等比），保证所有键数字上对齐
                        // 星号字形本身偏小（约 # 的 60%），仅渲染放大做视觉补偿；字号保持与 # 一致避免行高偏移
                        .scaleEffect(num == "*" ? 2.15 : 1)
                        .offset(y: num == "*" ? numFont * 0.4 : 0)
                        .foregroundColor(colorScheme == .dark ? .white : .black)

                    // 字母行固定占位（空键用空格），保证所有键的字母行在同一高度
                    Text(letters.isEmpty ? " " : letters)
                        .font(.system(size: letterFont, weight: .medium))
                        .foregroundColor(colorScheme == .dark ? Color.white.opacity(0.85) : Color.black.opacity(0.45))
                        .tracking(letterFont * 0.145)
                        .frame(height: letterFont * 1.18)
                }
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.05), radius: 5, y: 2)
        }
        .buttonStyle(DialButtonStyle())
        .frame(width: size, height: size)
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

    /// 连接指示点：演示模式恒绿（演示即"永远已连接"），否则按实际连接状态
    private var connectionDotColor: Color {
        callManager.demoMode || callManager.isConnected ? .green : .red
    }

    /// 连接状态文本：演示模式显示运营商/已连接，与指示点语义一致
    private var connectionStatusText: String {
        callManager.moduleInfo?.operator_name ?? (connectionDotColor == .green ? "已连接" : "连接中…")
    }

    @State private var historySideTab = 0  // 外屏通话记录页内容切换：0=通话记录 1=联系人

    private var historyView: some View {
        // 展开形态下总 tab 已隐藏本入口（拨号页左栏承接通话/联系人），
        // 此视图仅窄屏使用；宽屏分支用官方 size class 判定（禁用宽度阈值）
        GeometryReader { _ in
            if isWideFormat {
                HStack(spacing: 0) {
                    historyList
                        .frame(maxWidth: .infinity)
                    contactsPanel
                        .frame(maxWidth: .infinity)
                }
            } else {
                // 外屏：顶部「最近通话 | 联系人」分段选项卡（与拨号页左栏交互一致）
                VStack(spacing: 0) {
                    Picker("", selection: $historySideTab) {
                        Text("最近通话").tag(0)
                        Text("联系人").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    if historySideTab == 0 {
                        historyList
                    } else {
                        contactsPanel
                    }
                }
            }
        }
    }

    /// 双栏左栏：通讯录面板（复用 ContactsView 的授权逻辑，点击直接拨号）
    private var contactsPanel: some View {
        ContactsView(callManager: callManager, contactManager: contactManager, onDial: {
            selectedTab = 1
        })
    }

    /// 拨号左栏紧凑版联系人面板（隐藏搜索栏、卡片行样式）
    private func contactsPanel(compactStyle: Bool) -> some View {
        ContactsView(callManager: callManager, contactManager: contactManager,
                     onDial: { selectedTab = 1 },
                     compactStyle: compactStyle)
    }

    /// 通话记录列表（单栏/双栏左栏共用）
    private var historyList: some View {
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
                Section {
                    ForEach(callManager.callHistory.prefix(50), id: \.id) { call in
                    // 整行点按 → 跳到拨号键盘并自动填入号码（不直接拨出）
                    Button {
                        dialNumber = call.number ?? ""
                        selectedTab = 1
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: recentCallIconName(call))
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(callIconColor(call))
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(contactManager.name(for: call.number) ?? formatNumber(call.number ?? "未知"))
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.appPrimary)
                                Text("\(callDirectionText(call)) · \(call.started_at ?? "")")
                                    .font(.system(size: 12))
                                    .foregroundColor(.appSecondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.appSecondary.opacity(0.5))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 10)
                }
                .onDelete { indexSet in
                    // 滑动删除：先取要删的 id，再逐条删除（本地 + 服务器）
                    let ids = indexSet.map { callManager.callHistory[$0].id }
                    for id in ids {
                        callManager.removeHistory(id: id)
                    }
                }
                }  // Section
            }
        }
        .listStyle(.plain)
        // 顶部不留空：plain 样式无分组间距，首行紧贴选项卡
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