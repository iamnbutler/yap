import Core
import Foundation
import Security

/// The OpenAI key, in the app's own Keychain: the same item as the Mac's
/// (`Secrets.openAIKeychain`), with an accessibility iOS needs.
///
/// Not the app group, where the keyboard (Full Access) could read it, and the
/// keyboard never needs the key.
enum APIKey {
    // Readable while locked, after the first unlock: a dictation can end
    // with the phone locked, and it still has to be transcribed.
    private static let item = KeychainItem(
        service: "dev.yap.Yap", account: Secrets.openAIKeyName,
        accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)

    static func read() -> String? {
        (try? item.read()) ?? nil
    }

    /// Saves `key`, or deletes it when empty.
    static func save(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return try item.delete() }
        try item.save(key)
    }

    /// "sk-…abcd", to show that a key is set without showing it.
    static var masked: String? {
        guard let key = read() else { return nil }
        return "\(key.prefix(3))…\(key.suffix(4))"
    }
}
