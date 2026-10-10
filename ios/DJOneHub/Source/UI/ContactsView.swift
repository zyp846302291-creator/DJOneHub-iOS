import SwiftUI
import Contacts

struct ContactsView: View {
    @ObservedObject var callManager: CallManager
    @ObservedObject var contactManager: ContactManager
    var onDial: (() -> Void)?
    @State private var filtered: [ContactItem] = []
    @State private var searchText = ""
    @State private var authStatus: CNAuthorizationStatus = .notDetermined

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
        .background(Color.appBackground.ignoresSafeArea())
        .onAppear {
            checkAuth()
        }
        .onChange(of: contactManager.contacts.count) { _ in
            filterContacts()
        }
    }

    private var mainList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.appSecondary)
                TextField("搜索联系人", text: $searchText)
                    .foregroundColor(.appPrimary)
                    .onChange(of: searchText) { _ in
                        filterContacts()
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.appSecondary)
                    }
                }
            }
            .padding(10)
            .background(Color.appFill.opacity(0.5))
            .cornerRadius(10)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if contactManager.contacts.isEmpty {
                Spacer()
                ProgressView()
                    .tint(.appPrimary)
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                Text(searchText.isEmpty ? "无联系人" : "无匹配结果")
                    .foregroundColor(.appSecondary)
                Spacer()
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
                    .frame(width: 40, height: 40)
                Text(String(contact.name.prefix(1)))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.appPrimary)
                if let phone = contact.phones.first {
                    Text(phone)
                        .font(.system(size: 13))
                        .foregroundColor(.appSecondary)
                }
            }

            Spacer()

            if !contact.phones.isEmpty {
                Image(systemName: "phone.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.green)
                    .clipShape(Circle())
            }
        }
        .padding(.vertical, 6)
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
