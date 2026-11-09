import Foundation
import Security

/// Somewhere to keep one secret. The Keychain in the apps, a dictionary in
/// tests.
public protocol SecretStore: Sendable {
    /// The secret, or nil when there is none.
    func read() throws -> String?
    /// Whether there is one, without reading it.
    var exists: Bool { get }
    /// Replaces the secret.
    func save(_ value: String) throws
    /// Removes the secret, if there is one.
    func delete() throws
}

/// A generic password in the Keychain.
///
/// On the Mac this is the login keychain, and the item's access list names
/// the app that created it by its designated requirement: bundle id plus
/// signing certificate, not the build's hash. So a rebuild signed with the
/// same certificate reads it without a prompt; an ad-hoc build would not.
public struct KeychainItem: SecretStore {
    public let service: String
    public let account: String
    /// `kSecAttrAccessible…`, for iOS, where a value matters. Nil leaves the
    /// default.
    public let accessible: String?

    public init(service: String, account: String, accessible: CFString? = nil) {
        self.service = service
        self.account = account
        self.accessible = accessible.map { $0 as String }
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() throws -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8),
            !value.isEmpty
        else { return nil }
        return value
    }

    /// Asks for the item's attributes, not its data, so it never needs the
    /// access list and never raises a prompt.
    public var exists: Bool {
        var search = query
        search[kSecReturnAttributes as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess
    }

    /// Deletes and adds rather than updating: an update keeps the old item's
    /// access list, and a new one names the app saving it.
    public func save(_ value: String) throws {
        try delete()
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "Yap: \(account)"
        if let accessible { item[kSecAttrAccessible as String] = accessible }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "Keychain: \(message)"
    }
}
