import Foundation
import Security

/// The OpenAI key, in the app's own Keychain.
///
/// Not `secrets.env` as on the Mac: that file would sit in the app group,
/// where the keyboard can read it, and the keyboard never needs the key. The
/// Mac's reasons against the Keychain (a prompt for every rebuilt signature)
/// don't apply on iOS, where an app always reads its own items.
enum APIKey {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.yap.Yap",
            kSecAttrAccount as String: "OPENAI_API_KEY",
        ]
    }

    static func read() -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    /// Saves `key`, or deletes it when empty.
    static func save(_ key: String) throws {
        SecItemDelete(query as CFDictionary)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        // Readable while locked, after the first unlock: a dictation can end
        // with the phone locked, and it still has to be transcribed.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// "sk-…abcd", to show that a key is set without showing it.
    static var masked: String? {
        guard let key = read() else { return nil }
        return "\(key.prefix(3))…\(key.suffix(4))"
    }
}
