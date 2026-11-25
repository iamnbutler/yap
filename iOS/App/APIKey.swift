import Core
import Foundation
import Security

/// The OpenAI key, in the app's own Keychain.
///
/// Not `secrets.env`: that file would sit in the app group, where the
/// keyboard can read it, and the keyboard never needs the key. And not the
/// Mac's item (service `OPENAI_API_KEY`, account the user name): an iOS app
/// reads only its own items, so this one is the app's.
enum APIKey {
    private static let item = KeychainItem(service: "dev.yap.Yap", account: "OPENAI_API_KEY")

    static func read() -> String? { item.read() }

    /// Saves `key`, or deletes it when empty.
    static func save(_ key: String) throws {
        // Readable while locked, after the first unlock: a dictation can end
        // with the phone locked, and it still has to be transcribed.
        try item.save(
            key,
            attributes: [
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ])
    }

    /// "sk-…abcd", to show that a key is set without showing it.
    static var masked: String? {
        guard let key = read() else { return nil }
        return "\(key.prefix(3))…\(key.suffix(4))"
    }
}
