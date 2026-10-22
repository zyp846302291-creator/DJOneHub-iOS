import SwiftUI
import Contacts

/// 条件 searchable：仅标准模式启用原生搜索栏（紧凑模式无导航栏，不适用）
struct SearchableIfAvailable: ViewModifier {
    var active: Bool
    @Binding var text: String
    func body(content: Content) -> some View {
        if active {
            content.searchable(text: $text,
                               placement: .navigationBarDrawer(displayMode: .always),
                               prompt: "搜索联系人")
        } else {
            content
        }
    }
}

/// 联系人行的背景修饰：紧凑模式给圆角卡片背景，普通模式透明
struct ContactRowCard: ViewModifier {
    var compact: Bool
    func body(content: Content) -> some View {
        if compact {
            content.background(Color.appFill.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        } else {
            content
        }
    }
}

struct ContactsView: View {
    @ObservedObject var callManager: CallManager
    @ObservedObject var contactManager: ContactManager
    var onDial: (() -> Void)?
    /// compactStyle：嵌入拨号左栏时用内嵌搜索框+卡片行（无导航栏，searchable 不适用）
    var compactStyle: Bool = false
    /// 外部搜索绑定（标准模式由外层导航容器 .searchable 驱动；不传则用内部状态）
    var externalSearchText: Binding<String>?
    @State private var filtered: [ContactItem] = []
    @State private var internalSearchText = ""
    @State private var authStatus: CNAuthorizationStatus = .notDetermined

    private var searchTextBinding: Binding<String> {
        externalSearchText ?? $internalSearchText
    }
    private var searchText: String {
        searchTextBinding.wrappedValue
    }

    var body: some View {
        Group {
            if authStatus == .notDetermined {
                VStack(spacing: 16) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    Text("需要通讯录权限")
                        .foregroundColor(.appPrimary)
                    Button("允许访问通讯录") {
                        requestAccess()
                    }
                    .foregroundColor(.blue)
                }
            } else if authStatus == .authorized {
                mainList
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .font(.system(size: 48))
                        .foregroundColor(.gray)
                    Text("通讯录权限受限")
                        .foregroundColor(.appPrimary)
                    Text("请在系统设置中允许访问通讯录")
                        .font(.system(size: 13))
                        .foregroundColor(.appSecondary)
                    Button("打开设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .foregroundColor(.blue)
                }
            }
        }
        // 嵌入面板（通话记录右栏）时不扩张背景，避免盖住中间分割线
        .background(Color.appBackground)
        .onChange(of: searchText) { _ in
            filterContacts()
        }
        .onAppear {
            checkAuth()
        }
        .onChange(of: contactManager.contacts.count) { _ in
            filterContacts()
        }
    }

    private var mainList: some View {
        Group {
            if contactManager.contacts.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                        .tint(.appPrimary)
                    Spacer()
                }
            } else if filtered.isEmpty {
                VStack {
                    Spacer()
                    Text(internalSearchText.isEmpty ? "无联系人" : "无匹配结果")
                        .foregroundColor(.appSecondary)
                    Spacer()
                }
            } else if compactStyle {
                // 紧凑模式：纯列表（滚动与垂直居中由外层 ScrollView 统一接管）
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { contact in
                        contactRow(contact)
                            .padding(.vertical, 4)
                    }
                }
            } else {
                List {
                    ForEach(filtered) { contact in
                        contactRow(contact)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func contactRow(_ contact: ContactItem) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(colorForName(contact.name))
                    .frame(width: 32, height: 32)
                Text(String(contact.name.prefix(1)))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.appPrimary)
                if let phone = contact.phones.first {
                    Text(phone)
                        .font(.system(size: 12))
                        .foregroundColor(.appSecondary)
                }
            }

            Spacer()

            if !contact.phones.isEmpty {
                // 原生联系人风格：灰底圆形 + 蓝色话筒图标
                Image(systemName: "phone.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.blue)
                    .frame(width: 30, height: 30)
                    .background(Color(.systemGray5))
                    .clipShape(Circle())
            }
        }
        // 紧凑模式（拨号左栏）：圆角卡片行，与最近通话列表风格统一
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .modifier(ContactRowCard(compact: compactStyle))
        .contentShape(Rectangle())
        .onTapGesture {
            if let phone = contact.phones.first {
                callManager.dial(number: phone)
                onDial?()
            }
        }
    }

    // MARK: - Logic

    private func checkAuth() {
        authStatus = CNContactStore.authorizationStatus(for: .contacts)
        if authStatus == .authorized {
            contactManager.loadContacts()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                filterContacts()
            }
        }
    }

    private func requestAccess() {
        CNContactStore().requestAccess(for: .contacts) { granted, _ in
            DispatchQueue.main.async {
                authStatus = granted ? .authorized : .denied
                if granted {
                    contactManager.loadContacts()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        filterContacts()
                    }
                }
            }
        }
    }

    private func filterContacts() {
        if searchText.isEmpty {
            filtered = contactManager.contacts
        } else {
            let q = searchText.lowercased()
            filtered = contactManager.contacts.filter {
                $0.name.lowercased().contains(q) ||
                $0.phones.contains { $0.contains(q) }
            }
        }
    }

    private func colorForName(_ name: String) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .green, .red, .pink, .teal, .cyan]
        let hash = abs(name.hashValue)
        return colors[hash % colors.count]
    }
}
