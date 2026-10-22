import Foundation
import Contacts
import UIKit

struct ContactItem: Identifiable {
    let id = UUID()
    let name: String
    let phones: [String]
    let imageData: Data?
}

/// 全局联系人管理器：加载通讯录，提供号码→姓名/头像查询
class ContactManager: ObservableObject {
    @Published var contacts: [ContactItem] = []
    
    private var phoneToName: [String: String] = [:] // 规范化号码 → 姓名
    private var phoneToImage: [String: Data] = [:]  // 规范化号码 → 头像
    
    func loadContacts() {
        // 联系人枚举是耗时 I/O，放后台线程执行，避免阻塞主线程（Contacts 框架会报 main-thread 警告）
        DispatchQueue.global(qos: .userInitiated).async {
            let store = CNContactStore()
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactThumbnailImageDataKey as CNKeyDescriptor
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var result: [ContactItem] = []
            var lookup: [String: String] = [:]
            var imageLookup: [String: Data] = [:]

            try? store.enumerateContacts(with: request) { cnContact, _ in
                let name = "\(cnContact.familyName)\(cnContact.givenName)"
                let phones = cnContact.phoneNumbers.map { $0.value.stringValue }
                let image = cnContact.thumbnailImageData
                if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    result.append(ContactItem(name: name, phones: phones, imageData: image))
                    for phone in phones {
                        let key = self.normalize(phone)
                        lookup[key] = name
                        if let image { imageLookup[key] = image }
                    }
                }
            }

            DispatchQueue.main.async {
                self.contacts = result
                self.phoneToName = lookup
                self.phoneToImage = imageLookup
            }
        }
    }
    
    /// 根据号码查找联系人姓名
    func name(for phone: String?) -> String? {
        guard let phone = phone else { return nil }
        let normalized = normalize(phone)
        if let name = phoneToName[normalized] {
            return name
        }
        for (key, name) in phoneToName {
            if normalized.hasSuffix(key) && key.count >= 7 {
                return name
            }
            if key.hasSuffix(normalized) && normalized.count >= 7 {
                return name
            }
        }
        return nil
    }
    
    /// 根据号码查找联系人头像（无则 nil）
    func imageData(for phone: String?) -> Data? {
        guard let phone = phone else { return nil }
        let normalized = normalize(phone)
        if let image = phoneToImage[normalized] {
            return image
        }
        for (key, image) in phoneToImage {
            if normalized.hasSuffix(key) && key.count >= 7 {
                return image
            }
            if key.hasSuffix(normalized) && normalized.count >= 7 {
                return image
            }
        }
        return nil
    }
    
    private func normalize(_ phone: String) -> String {
        return phone.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
    }
}
