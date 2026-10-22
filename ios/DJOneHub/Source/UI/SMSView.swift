import SwiftUI

struct SMSView: View {
    @ObservedObject var api: APIClient
    @Binding var unreadSMS: Int
    // 官方判定：内屏（regular）时详情栏也显示新信息按钮
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var messages: [SMSMessage] = []
    @State private var conversations: [SMSConversation] = []
    @State private var selectedConversation: SMSConversation?
    @State private var isLoading = false
    @State private var showSendForm = false
    @State private var sendPhone = ""
    @State private var sendMessage = ""
    @State private var sendStatus: String?
    @State private var showClearAlert = false
    @State private var deleteTarget: SMSConversation?
    @State private var readConversations: [String: String] = [:] // number -> lastReadTimestamp
    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case phone, message, reply
    }

    var body: some View {
        // compact（iPhone 竖屏）：直接栈式（列表 ↔ 会话），避开 NavigationSplitView
        // 在 iPhone 折叠模式下的首帧不渲染 bug（旋转才出现）；
        // regular（iPad/展开）：官方 NavigationSplitView 双栏
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView(columnVisibility: .constant(.all)) {
                    sidebarContent
                } detail: {
                    detailContent
                }
                .navigationSplitViewStyle(.balanced)
                .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 480)
            } else {
                Group {
                    if let conv = selectedConversation {
                        threadView(conv, showsBackButton: true)
                    } else {
                        sidebarContent
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .onTapGesture { focusedField = nil }
        .onAppear {
            loadReadStatus()
            Task { await loadSMS() }
        }
        .refreshable { await loadSMS() }
        .sheet(isPresented: $showCompose) { composeView }
        .alert("清空全部短信？", isPresented: $showClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                Task { await clearSMS() }
            }
        }
        .alert("删除该会话？", isPresented: .constant(deleteTarget != nil)) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) {
                if let conv = deleteTarget {
                    deleteConversation(conv)
                    deleteTarget = nil
                }
            }
        } message: {
            Text("将删除与 \(deleteTarget?.number ?? "") 的全部短信")
        }
    }

    /// 侧栏/列表内容（两种形态共用）
    private var sidebarContent: some View {
        conversationsListBody
            .navigationTitle("信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCompose = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
    }

    /// 详情内容（regular 双栏右栏）
    private var detailContent: some View {
        Group {
            if let conv = selectedConversation {
                threadView(conv, showsBackButton: false)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "message")
                        .font(.system(size: 44))
                        .foregroundColor(.appSecondary.opacity(0.5))
                    Text("选择左侧会话查看短信")
                        .font(.system(size: 15))
                        .foregroundColor(.appSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Compose（新建短信，原生信息 App 风格）

    @State private var showCompose = false

    private var composeView: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 收件人（原生样式：无边框 + 底部分隔线，自动带 + 联系人按钮）
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 22))
                        .foregroundColor(.appSecondary)
                    TextField("收件人", text: $sendPhone)
                        .keyboardType(.phonePad)
                        .font(.system(size: 16))
                        .focused($focusedField, equals: .phone)
                    if !sendPhone.isEmpty {
                        Button {
                            sendPhone = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.appSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { Divider() }

                // 内容输入区（多行自适应，占满剩余空间）
                ScrollView {
                    TextField("短信内容", text: $sendMessage, axis: .vertical)
                        .lineLimit(3...8)
                        .font(.system(size: 16))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .focused($focusedField, equals: .message)
                }

                // 发送状态提示
                if let status = sendStatus {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundColor(status.contains("成功") ? .green : .red)
                        .padding(.vertical, 4)
                }

                // 发送按钮（右下角胶囊，原生风格）
                HStack {
                    Spacer()
                    Button {
                        Task {
                            await sendSMS()
                            // 发送成功后自动关闭
                            if sendStatus?.contains("成功") == true {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                showCompose = false
                                sendStatus = nil
                                await loadSMS()
                            }
                        }
                    } label: {
                        Text("发送")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(sendPhone.isEmpty || sendMessage.isEmpty ? Color.gray : Color.blue, in: Capsule())
                    }
                    .disabled(sendPhone.isEmpty || sendMessage.isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .navigationTitle("新信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        sendStatus = nil
                        showCompose = false
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// 会话列表主体（原生 List 铺满）
    private var conversationsListBody: some View {
        Group {
            if conversations.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "message")
                        .font(.system(size: 40))
                        .foregroundColor(.appSecondary)
                    Text(isLoading ? "正在加载..." : "暂无短信")
                        .font(.system(size: 15))
                        .foregroundColor(.appSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(conversations) { conv in
                        Button {
                            markAsRead(conv)
                            selectedConversation = conv
                        } label: {
                            conversationRow(conv)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteConversation(conv)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            // 原生信息同款：标为未读（蓝）
                            Button {
                                readConversations[conv.number] = ""
                                UserDefaults.standard.set(readConversations, forKey: "smsReadStatus")
                            } label: {
                                Label("标为未读", systemImage: "envelope.badge")
                            }
                            .tint(.blue)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func conversationRow(_ conv: SMSConversation) -> some View {
        let isUnread = (readConversations[conv.number] ?? "") < conv.lastMessage.timestamp
        return HStack(spacing: 12) {
            // 原生信息风格：未读行首蓝点
            Circle()
                .fill(Color.blue)
                .frame(width: 10, height: 10)
                .opacity(isUnread ? 1 : 0)   // 恒占位，布局稳定

            // Avatar
            Circle()
                .fill(Color.blue.opacity(0.2))
                .frame(width: 44, height: 44)
                .overlay(
                    Text(String(conv.number.suffix(2)))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.blue)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(formatNumber(conv.number))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.appPrimary)
                    Spacer()
                    Text(formatTimestamp(conv.lastMessage.timestamp))
                        .font(.system(size: 12))
                        .foregroundColor(.appSecondary)
                }

                HStack {
                    Text(conv.lastMessage.content)
                        .font(.system(size: 14))
                        .foregroundColor(.appSecondary)
                        .lineLimit(1)
                    Spacer()
                    // 预览行快捷复制验证码（不用进会话）
                    if let code = extractVerificationCode(from: conv.lastMessage.content) {
                        Button {
                            UIPasteboard.general.string = code
                            copiedCode = code
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                if copiedCode == code { copiedCode = nil }
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copiedCode == code ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 10, weight: .medium))
                                Text(copiedCode == code ? "已复制" : code)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                            }
                            .foregroundColor(copiedCode == code ? .green : .blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    let isUnreadBadge = (readConversations[conv.number] ?? "") < conv.lastMessage.timestamp
                    if isUnreadBadge {
                        // 已由行首蓝点替代（原生信息风格），此处保留占位不影响布局
                        EmptyView()
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Thread View

    private func threadView(_ conv: SMSConversation, showsBackButton: Bool = true) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if showsBackButton {
                    Button {
                        selectedConversation = nil
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.blue)
                    }
                }

                VStack(alignment: .leading) {
                    Text(formatNumber(conv.number))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.appPrimary)
                    Text("\(conv.messages.count) 条短信")
                        .font(.system(size: 12))
                        .foregroundColor(.appSecondary)
                }

                Spacer()

                Button {
                    deleteTarget = conv
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 18))
                        .foregroundColor(.red)
                }

                Button {
                    // 转发：打开新建页并预填收件人
                    sendPhone = conv.number
                    sendMessage = ""
                    selectedConversation = nil
                    showCompose = true
                } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 18))
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemGray6).opacity(0.5))

            Divider()

            // Messages
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(conv.messages) { msg in
                        messageBubble(msg)
                    }
                }
                .padding(16)
            }
            .onTapGesture { focusedField = nil }

            Divider()

            // Reply form
            HStack(spacing: 8) {
                TextField("回复短信...", text: $sendMessage)
                    .focused($focusedField, equals: .reply)
                    .textFieldStyle(.roundedBorder)

                Button {
                    sendPhone = conv.number
                    Task { await sendSMS() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(sendMessage.isEmpty ? .gray : .blue)
                }
                .disabled(sendMessage.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func messageBubble(_ msg: SMSMessage) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(msg.content)
                    .font(.system(size: 15))
                    .foregroundColor(.appPrimary)
                    .padding(10)
                    .background(Color(.systemGray4))
                    .cornerRadius(12)

                // 验证码快捷复制（自动提取到验证码时显示）
                if let code = extractVerificationCode(from: msg.content) {
                    Button {
                        UIPasteboard.general.string = code
                        copiedCode = code
                        // 1.2 秒后恢复按钮文案
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            if copiedCode == code { copiedCode = nil }
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: copiedCode == code ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                            Text(copiedCode == code ? "已复制" : "复制验证码 \(code)")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(copiedCode == code ? .green : .blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Text(formatTimestamp(msg.timestamp))
                    .font(.system(size: 11))
                    .foregroundColor(.appSecondary)
            }
            Spacer()
        }
    }

    // MARK: - Verification Code

    @State private var copiedCode: String?

    /// 从短信内容自动提取验证码：
    /// 优先匹配"验证码/校验码/动态码/密码 + 4-8 位数字"模式；
    /// 否则在含验证码语义的短信里取第一段独立 4-8 位数字（前后非数字）。
    private func extractVerificationCode(from content: String) -> String? {
        let keywords = ["验证码", "校验码", "动态码", "识别码", "确认码", "authorization", "code", "verifikasi"]
        let lower = content.lowercased()
        let hasKeyword = keywords.contains { lower.contains($0.lowercased()) }
        guard hasKeyword else { return nil }

        // 模式 1：关键词后（允许少量非数字字符间隔）紧跟 4-8 位数字
        for kw in ["验证码", "校验码", "动态码", "识别码", "确认码"] {
            if let range = content.range(of: kw) {
                let after = content[range.upperBound...]
                if let m = after.range(of: #"(?<!\d)(\d{4,8})(?!\d)"#, options: .regularExpression) {
                    // 间隔不超过 6 个字符，避免匹配到别处的数字
                    if m.lowerBound.utf16Offset(in: after) <= 6 {
                        return String(content[m])
                    }
                }
            }
        }
        // 模式 1b：英文 code 后的数字
        if let range = lower.range(of: "code") {
            let after = content[range.upperBound...]
            if let m = after.range(of: #"(?<!\d)(\d{4,8})(?!\d)"#, options: .regularExpression) {
                if m.lowerBound.utf16Offset(in: after) <= 8 {
                    return String(content[m])
                }
            }
        }
        // 模式 2：短信里第一段独立 4-8 位数字（不含分隔符的纯数字段）
        if let m = content.range(of: #"(?<!\d)(\d{4,8})(?!\d)"#, options: .regularExpression) {
            return String(content[m])
        }
        return nil
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Button {
                Task { await loadSMS() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
                    .font(.system(size: 13))
            }

            Spacer()

            Button {
                showClearAlert = true
            } label: {
                Label("清空", systemImage: "trash")
                    .font(.system(size: 13))
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Read Status

    private func loadReadStatus() {
        if let saved = UserDefaults.standard.dictionary(forKey: "smsReadStatus") as? [String: String] {
            readConversations = saved
        }
        updateUnreadCount()
    }

    private func markAsRead(_ conv: SMSConversation) {
        readConversations[conv.number] = conv.lastMessage.timestamp
        UserDefaults.standard.set(readConversations, forKey: "smsReadStatus")
        updateUnreadCount()
    }

    /// 计算未读会话数（供 tab 角标使用）
    private func updateUnreadCount() {
        unreadSMS = conversations.filter {
            (readConversations[$0.number] ?? "") < $0.lastMessage.timestamp
        }.count
    }

    // MARK: - Actions

    private func loadSMS() async {
        isLoading = true
        defer { isLoading = false }
        do {
            messages = try await api.fetchSMS()
            buildConversations()
        } catch {
            print("[SMS] load error: \(error)")
        }
    }

    private func sendSMS() async {
        guard !sendPhone.isEmpty, !sendMessage.isEmpty else { return }
        do {
            let result = try await api.sendSMS(phone: sendPhone, message: sendMessage)
            if result.sent == true {
                sendStatus = "发送成功（\(result.segments ?? 1) 条）"
                sendMessage = ""
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await loadSMS()
            } else {
                sendStatus = result.error ?? "发送失败"
            }
        } catch {
            sendStatus = "发送失败: \(error.localizedDescription)"
        }
    }

    private func clearSMS() async {
        do {
            _ = try await api.clearSMS()
            messages = []
            conversations = []
        } catch {
            print("[SMS] clear error: \(error)")
        }
    }

    private func deleteConversation(_ conv: SMSConversation) {
        messages.removeAll { $0.sender == conv.number }
        buildConversations()
        selectedConversation = nil
    }

    private func buildConversations() {
        var convMap: [String: [SMSMessage]] = [:]
        for msg in messages {
            convMap[msg.sender, default: []].append(msg)
        }
        conversations = convMap.map { key, msgs in
            SMSConversation(number: key, messages: msgs.sorted { $0.timestamp < $1.timestamp })
        }.sorted { $0.lastMessage.timestamp > $1.lastMessage.timestamp }
        updateUnreadCount()
    }

    // MARK: - Helpers

    private func formatNumber(_ n: String) -> String {
        let clean = n.replacingOccurrences(of: " ", with: "")
        if clean.count == 11, clean.hasPrefix("1") {
            let a = clean.index(clean.startIndex, offsetBy: 3)
            let b = clean.index(clean.startIndex, offsetBy: 7)
            return "\(clean[..<a]) \(clean[a..<b]) \(clean[b...])"
        }
        return n
    }

    private func formatTimestamp(_ ts: String) -> String {
        // Parse ISO 8601 timestamp
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: ts) {
            let cal = Calendar.current
            if cal.isDateInToday(date) {
                let df = DateFormatter()
                df.dateFormat = "HH:mm"
                return df.string(from: date)
            } else if cal.isDateInYesterday(date) {
                return "昨天"
            } else {
                let df = DateFormatter()
                df.dateFormat = "MM/dd"
                return df.string(from: date)
            }
        }
        // Fallback: try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: ts) {
            let df = DateFormatter()
            df.dateFormat = cal_isToday(date) ? "HH:mm" : "MM/dd"
            return df.string(from: date)
        }
        return String(ts.prefix(10))
    }

    private func cal_isToday(_ date: Date) -> Bool {
        Calendar.current.isDateInToday(date)
    }
}
