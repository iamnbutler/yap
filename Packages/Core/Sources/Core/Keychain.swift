import Foundation
import Security

/// One generic password in the Keychain, by service and account.
///
/// On the Mac this is the login Keychain, so an item made with
/// `security add-generic-password` is found here too. On iOS it's the app's own.
public struct KeychainItem: Sendable, Equatable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    /// What a read found.
    public enum Lookup: Sendable, Equatable {
        case found(String)
        case missing
        /// The item is there, but Yap may not read it: the user chose Deny
        /// when macOS asked, or there was nobody to ask.
        case denied
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Reads the secret. For an item another program made, macOS asks the user
    /// once whether Yap may read it, and blocks here until they answer.
    public func lookup() -> Lookup {
        var search = query
        search[kSecReturnData as String] = true
        var item: CFTypeRef?
        switch SecItemCopyMatching(search as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8)
            else { return .missing }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .missing : .found(trimmed)
        case errSecItemNotFound:
            return .missing
        default:
            return .denied
        }
    }

    public func read() -> String? {
        if case .found(let value) = lookup() { return value }
        return nil
    }

    /// Whether the item exists, without reading the secret, so it never
    /// raises the access prompt. Cheap enough to poll.
    public var exists: Bool {
        var search = query
        search[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        return SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess
    }

    /// Saves `value`, changing the item in place when it exists, so its access
    /// list (which programs may read it without asking) stays as it was.
    /// `attributes` apply only when the item is new. An empty value deletes it.
    public func save(_ value: String, attributes: [String: Any] = [:]) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return delete() }
        let data = Data(value.utf8)
        var status = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
