import SwiftUI

struct MoreView: View {
    @ObservedObject var api: APIClient
    @AppStorage("serverHost") private var serverHost = "100.100.221.117"
    @AppStorage("serverPort") private var serverPort = 7576
    @AppStorage("appTheme") private var appTheme = "system" // system / light / dark
    @AppStorage("demoMode") private var demoMode = false
    @State private var hostInput = ""
    @State private var portInput = ""
    @State private var showSaved = false

    var body: some View {
        List {
            Section {                // 外观模式：跟随系统 / 浅色 / 深色
                Picker("外观模式", selection: $appTheme) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
            } header: {
                Text("外观")
            } footer: {
                Text("通话界面与系统通话界面一致，始终为深色")
            }

            Section {
                NavigationLink {
                    NetworkView(api: api)
                } label: {
                    rowItem(icon: "wifi", title: "网络", subtitle: "4G 网络诊断", color: .blue)
                }

                NavigationLink {
                    GPSView(api: api)
                } label: {
                    rowItem(icon: "location", title: "定位", subtitle: "GNSS 定位", color: .green)
                }

                NavigationLink {
                    ESIMView(api: api)
                } label: {
                    rowItem(icon: "simcard", title: "eSIM / 卡片", subtitle: "eSIM Profile 管理", color: .orange)
                }

                NavigationLink {
                    ATDebugView(api: api)
                } label: {
                    rowItem(icon: "terminal", title: "AT 调试", subtitle: "发送 AT 指令", color: .purple)
                }
            } header: {
                Text("功能")
            }

            Section {
                VStack(spacing: 8) {
                    HStack {
                        Text("地址")
                            .frame(width: 44, alignment: .leading)
                        TextField("服务器地址或IP", text: $hostInput)
                            .textFieldStyle(.roundedBorder)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    HStack {
                        Text("端口")
                            .frame(width: 44, alignment: .leading)
                        TextField("7576", text: $portInput)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numberPad)
                    }
                    Button {
                        serverHost = hostInput.isEmpty ? serverHost : hostInput
                        if let p = Int(portInput), p > 0 {
                            serverPort = p
                        }
                        showSaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showSaved = false }
                    } label: {
                        HStack {
                            Spacer()
                            if showSaved {
                                Text("已保存，重启App生效")
                                    .foregroundColor(.green)
                            } else {
                                Text("保存")
                                    .foregroundColor(.white)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .background(showSaved ? Color.clear : Color.blue)
                        .cornerRadius(8)
                    }

                    // 当前连接地址（并入分组卡片内，非 footer 悬浮文字）
                    HStack {
                        Text("当前")
                            .font(.system(size: 13))
                            .foregroundColor(.appSecondary)
                        Spacer()
                        Text("\(serverHost):\(String(serverPort))")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.appPrimary)
                    }
                    .padding(.top, 4)
                }
                .listRowSeparator(.hidden)
            } header: {
                Text("服务器连接")
            }

            Section {
                Toggle("演示模式", isOn: $demoMode)
            } header: {
                Text("调试")
            } footer: {
                Text("开启后使用模拟数据展示全部界面，无需连接服务器。重启 App 生效。")
            }

            Section {
                HStack {
                    Spacer()
                    Text("DJOneHub v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                        .font(.system(size: 14))
                    Spacer()
                }
            }
        }
        .navigationTitle("更多")
        // 点击键盘以外的区域收起键盘（IP/端口输入无 Return 键可关）
        .onTapGesture {
            hideKeyboard()
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                hideKeyboard()
            }
        )
    }

    /// 收起系统键盘：让当前第一响应者辞职
    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    private func rowItem(icon: String, title: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(color)
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.appPrimary)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.appSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Network View

struct NetworkView: View {
    @ObservedObject var api: APIClient
    @State private var info: NetworkInfo?
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("USB 网络")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.appSecondary)
                        .textCase(.uppercase)

                    if let info = info {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            infoGrid(label: "USB模式", value: info.usbnet_mode ?? "—")
                            infoGrid(label: "USB配置", value: info.usbcfg ?? "—")
                        }
                    }
                }
                .padding(16)
                .background(Color.appFill.opacity(0.5))
                .cornerRadius(16)

                if let contexts = info?.pdp_contexts, !contexts.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("PDP 上下文")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.appSecondary)
                            .textCase(.uppercase)

                        ForEach(contexts, id: \.id) { ctx in
                            HStack {
                                Text("#\(ctx.id ?? 0)")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.appPrimary)
                                Text(ctx.pdn ?? "—")
                                    .font(.system(size: 13))
                                    .foregroundColor(.appSecondary)
                                Spacer()
                                Text(ctx.apn ?? "—")
                                    .font(.system(size: 14))
                                    .foregroundColor(.appPrimary)
                            }
                            .padding(10)
                            .background(Color(.systemGray6).opacity(0.3))
                            .cornerRadius(10)
                        }
                    }
                    .padding(16)
                    .background(Color.appFill.opacity(0.5))
                    .cornerRadius(16)
                }
            }
            .padding(16)
        }
        .navigationTitle("网络")
        .onAppear { Task { await load() } }
    }

    private func infoGrid(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundColor(.appSecondary)
            Text(value).font(.system(size: 14, weight: .medium)).foregroundColor(.appPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.systemGray6).opacity(0.3))
        .cornerRadius(10)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do { info = try await api.fetchNetwork() } catch { print("[Network] \(error)") }
    }
}

// MARK: - GPS View

struct GPSView: View {
    @ObservedObject var api: APIClient
    @State private var gps: GPSInfo?
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("GNSS 定位")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.appSecondary)
                            .textCase(.uppercase)
                        Spacer()
                        Button {
                            Task { await load() }
                        } label: {
                            Text("刷新")
                                .font(.system(size: 13))
                                .foregroundColor(.blue)
                        }
                    }

                    if let gps = gps {
                        HStack {
                            Circle()
                                .fill(gps.enabled == true ? Color.green : Color.gray)
                                .frame(width: 10, height: 10)
                            Text(gps.enabled == true ? "定位已开启" : "定位未开启")
                                .font(.system(size: 15))
                                .foregroundColor(.appPrimary)
                        }

                        if let fix = gps.last_fix {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                infoGrid(label: "纬度", value: String(format: "%.6f", fix.lat ?? 0))
                                infoGrid(label: "经度", value: String(format: "%.6f", fix.lon ?? 0))
                                infoGrid(label: "海拔", value: String(format: "%.1f m", fix.alt ?? 0))
                                infoGrid(label: "速度", value: String(format: "%.1f km/h", fix.speed ?? 0))
                                infoGrid(label: "卫星", value: "\(fix.satellites ?? 0)")
                                infoGrid(label: "精度", value: String(format: "%.1f", fix.hdop ?? 0))
                            }
                        } else {
                            Text("暂无定位数据")
                                .font(.system(size: 14))
                                .foregroundColor(.appSecondary)
                                .padding(.vertical, 10)
                        }

                        if let error = gps.last_error, !error.isEmpty {
                            Text("错误: \(error)")
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                        }
                    }
                }
                .padding(16)
                .background(Color.appFill.opacity(0.5))
                .cornerRadius(16)

                Text("室内可能无法获得定位。开启后模块将每 15 秒刷新一次。")
                    .font(.system(size: 12))
                    .foregroundColor(.appSecondary)
                    .padding(.horizontal, 16)

                Button {
                    Task {
                        let enable = gps?.enabled != true
                        _ = try? await api.toggleGPS(enable: enable)
                        await load()
                    }
                } label: {
                    Text(gps?.enabled == true ? "停止定位" : "启动定位")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                        .background(gps?.enabled == true ? Color.red : Color.blue)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("定位")
        .onAppear { Task { await load() } }
    }

    private func infoGrid(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundColor(.appSecondary)
            Text(value).font(.system(size: 14, weight: .medium)).foregroundColor(.appPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.systemGray6).opacity(0.3))
        .cornerRadius(10)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do { gps = try await api.fetchGPS() } catch { print("[GPS] \(error)") }
    }
}

// MARK: - eSIM View

struct ESIMView: View {
    @ObservedObject var api: APIClient
    @State private var esim: ESIMProfiles?
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let chip = esim?.chip {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("卡片信息")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.appSecondary)
                            .textCase(.uppercase)

                        LazyVGrid(columns: [GridItem(.flexible())], spacing: 8) {
                            infoGrid(label: "EID", value: chip.eid ?? "—")
                            infoGrid(label: "固件", value: chip.firmware ?? "—")
                        }
                    }
                    .padding(16)
                    .background(Color.appFill.opacity(0.5))
                    .cornerRadius(16)
                }

                if let profiles = esim?.profiles, !profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("已安装 Profile")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.appSecondary)
                            .textCase(.uppercase)

                        ForEach(profiles, id: \.iccid) { profile in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(profile.profile_name ?? profile.nickname ?? "未命名")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.appPrimary)
                                    Spacer()
                                    Text(profile.state ?? "—")
                                        .font(.system(size: 12))
                                        .foregroundColor(profile.state == "active" ? .green : .appSecondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color(.systemGray6))
                                        .cornerRadius(6)
                                }
                                if let provider = profile.provider {
                                    Text(provider)
                                        .font(.system(size: 13))
                                        .foregroundColor(.appSecondary)
                                }
                                if let iccid = profile.iccid {
                                    Text("ICCID: \(iccid)")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.appSecondary)
                                }
                            }
                            .padding(10)
                            .background(Color(.systemGray6).opacity(0.3))
                            .cornerRadius(10)
                        }
                    }
                    .padding(16)
                    .background(Color.appFill.opacity(0.5))
                    .cornerRadius(16)
                }

                if esim == nil && !isLoading {
                    Text("仅在 SIM 卡槽中插入 eUICC/eSIM 卡片时使用")
                        .font(.system(size: 14))
                        .foregroundColor(.appSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
            }
            .padding(16)
        }
        .navigationTitle("eSIM / 卡片")
        .toolbar {
            Button("刷新") { Task { await load() } }
        }
        .onAppear { Task { await load() } }
    }

    private func infoGrid(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundColor(.appSecondary)
            Text(value).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundColor(.appPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.systemGray6).opacity(0.3))
        .cornerRadius(10)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do { esim = try await api.fetchESIM() } catch { print("[eSIM] \(error)") }
    }
}

// MARK: - AT Debug View

struct ATDebugView: View {
    @ObservedObject var api: APIClient
    @State private var command = "AT+CSQ"
    @State private var output = "等待命令"
    @State private var isRunning = false

    var body: some View {
        VStack(spacing: 0) {
            // Command input
            HStack(spacing: 8) {
                TextField("AT 指令", text: $command)
                    .font(.system(size: 15, design: .monospaced))
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await execute() }
                } label: {
                    Text("执行")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(command.isEmpty || isRunning ? Color.gray : Color.blue)
                        .cornerRadius(8)
                }
                .disabled(command.isEmpty || isRunning)
            }
            .padding(16)

            Divider()

            // Quick commands
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    quickCmd("AT+CSQ", "信号")
                    quickCmd("AT+COPS?", "运营商")
                    quickCmd("AT+CPIN?", "SIM状态")
                    quickCmd("AT+CREG?", "注册")
                    quickCmd("AT+CGDCONT?", "APN")
                    quickCmd("ATI", "设备信息")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            Divider()

            // Output
            ScrollView {
                Text(output)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxWidth: 900, alignment: .leading) // 展开内屏限制行宽，保持可读性
                    .padding(16)
            }
            .frame(maxWidth: .infinity)
            .background(Color.black)
        }
        .navigationTitle("AT 调试")
    }

    private func quickCmd(_ cmd: String, _ label: String) -> some View {
        Button {
            command = cmd
            Task { await execute() }
        } label: {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
        }
    }

    private func execute() async {
        guard !command.isEmpty, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            let result = try await api.sendAT(command)
            output = result.response ?? result.error ?? "无响应"
        } catch {
            output = "错误: \(error.localizedDescription)"
        }
    }
}
