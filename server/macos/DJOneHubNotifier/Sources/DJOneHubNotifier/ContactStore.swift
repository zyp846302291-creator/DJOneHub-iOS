import Foundation
import Contacts
import Combine

/// 非隔离的联系人读取器：避免 MainActor 持有 CNContactStore 引发 Swift 6 并发检查。
struct ContactFetcher: Sendable {
    func requestAccess() async throws -> Bool {
        try await CNContactStore().requestAccess(for: .contacts)
    }

    func fetchAll() throws -> [ContactStore.Contact] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
            CNContactThumbnailImageDataKey,
            CNContactIdentifierKey,
        ] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        var result: [ContactStore.Contact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            // 中文姓名按「姓在前名在后」显示（张三），西文保持「名在前」（John Smith）
            let given = contact.givenName
            let family = contact.familyName
            let cjk = Self.containsCJK(given + family)
            let name: String
            if cjk {
                name = [family, given].filter { !$0.isEmpty }.joined(separator: "")
            } else {
                name = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
            }
            let phones = contact.phoneNumbers
                .compactMap { $0.value.stringValue }
                .map(ContactStore.normalized)
                .filter { !$0.isEmpty }
            guard !name.isEmpty, !phones.isEmpty else { return }
            let emails = contact.emailAddresses
                .compactMap { $0.value as String? }
                .filter { !$0.isEmpty }
            result.append(.init(
                id: contact.identifier,
                name: name,
                phones: phones,
                emails: emails,
                photoData: contact.thumbnailImageData
            ))
        }
        return result
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF,   // CJK 统一表意文字
                 0x3400...0x4DBF,   // 扩展 A
                 0xF900...0xFAFF,   // 兼容表意文字
                 0x3040...0x30FF:   // 日文假名（常见于联系人备注）
                return true
            default:
                return false
            }
        }
    }
}

/// 联系人数据中心：读取 macOS 系统通讯录（Contacts.framework），提供姓名解析。
@MainActor
final class ContactStore: ObservableObject {
    struct Contact: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let phones: [String]
        let emails: [String]
        let photoData: Data?
    }

    @Published var contacts: [Contact] = []
    @Published var isAuthorized = false
    @Published var authError: String?

    private let fetcher = ContactFetcher()

    nonisolated static func normalized(_ phone: String) -> String {
        var value = phone.filter { $0.isNumber || $0 == "+" }
        if value.hasPrefix("+86") {
            value = String(value.dropFirst(3))
        } else if value.hasPrefix("86"), value.count > 11 {
            value = String(value.dropFirst(2))
        }
        return value
    }

    func requestAccess() async {
        do {
            let granted = try await fetcher.requestAccess()
            isAuthorized = granted
            authError = granted ? nil : "未获得通讯录访问权限"
            if granted {
                await load()
            }
        } catch {
            authError = error.localizedDescription
        }
    }

    func load() async {
        do {
            contacts = try fetcher.fetchAll()
        } catch {
            authError = error.localizedDescription
        }
    }

    /// 精确匹配，再退化为长号码后缀匹配（≥7 位）。返回完整联系人（含照片/邮箱）。
    func contact(for number: String) -> Contact? {
        let target = Self.normalized(number)
        guard !target.isEmpty else { return nil }
        for contact in contacts where contact.phones.contains(target) {
            return contact
        }
        guard target.count >= 7 else { return nil }
        let suffix = String(target.suffix(7))
        for contact in contacts {
            for phone in contact.phones where phone.count >= 7 && phone.hasSuffix(suffix) {
                return contact
            }
        }
        return nil
    }

    func name(for number: String) -> String? {
        contact(for: number)?.name
    }

    /// 通话记录/短信/来电界面统一使用的显示名。
    func displayName(for number: String?) -> String {
        guard let number, !number.isEmpty else { return "未知号码" }
        return name(for: number) ?? number
    }
}
