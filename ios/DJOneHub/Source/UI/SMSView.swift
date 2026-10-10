import SwiftUI

struct SMSView: View {
    @ObservedObject var api: APIClient
    @Binding var unreadSMS: Int
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
        VStack(spacing: 0) {
            if let conv = selectedConversation {
                threadView(conv)
            } else {
                conversationList
            }
        }
        .onTapGesture { focusedField = nil }
        .onAppear {
            loadReadStatus()
            Task { await loadSMS() }
        }
        .refreshable { await loadSMS() }
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

    // MARK: - Conversation List

    private var conversationList: some View {
        VStack(spacing: 0) {
            // Send form
            sendFormSection

            // Conversations
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
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var sendFormSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("接收号码", text: $sendPhone)
                    .keyboardType(.phonePad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .focused($focusedField, equals: .phone)

                TextField("短信内容", text: $sendMessage)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .message)

                Button {
                    Task { await sendSMS() }
                } label: {
                    Text("发送")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(sendPhone.isEmpty || sendMessage.isEmpty ? Color.gray : Color.blue)
                        .cornerRadius(8)
                }
                .disabled(sendPhone.isEmpty || sendMessage.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if let status = sendStatus {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundColor(status.contains("成功") ? .green : .red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            Divider()
        }
        .background(Color(.systemGray6).opacity(0.5))
    }

    private func conversationRow(_ conv: SMSConversation) -> some View {
        HStack(spacing: 12) {
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
                    let isUnread = (readConversations[conv.number] ?? "") < conv.lastMessage.timestamp
                    if isUnread {
                        Text("未读")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.blue)
                            .cornerRadius(10)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Thread View

    private func threadView(_ conv: SMSConversation) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button {
                    selectedConversation = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.blue)
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
                    sendPhone = conv.number
                    selectedConversation = nil
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

                Text(formatTimestamp(msg.timestamp))
                    .font(.system(size: 11))
                    .foregroundColor(.appSecondary)
            }
            Spacer()
        }
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
