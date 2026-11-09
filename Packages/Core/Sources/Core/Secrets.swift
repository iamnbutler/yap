import Foundation

/// Resolves the OpenAI key: `OPENAI_API_KEY` in the environment, for
/// development, then the Keychain, where the menu's OpenAI Key item puts it.
///
/// Not a file: Yap used to read `secrets.env`, and a raw key on disk is what
/// this replaces. `migrateOpenAIKey` moves an old file's key into the Keychain.
public enum Secrets {
    public static let openAIKeyName = "OPENAI_API_KEY"

    /// The same service and account as the iPhone app's item.
    public static let openAIKeychain: any SecretStore = KeychainItem(
        service: "dev.yap.Yap", account: openAIKeyName)

    public static func openAIAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        store: any SecretStore = openAIKeychain
    ) throws -> String {
        if let key = environment[openAIKeyName], !key.isEmpty { return key }
        if let key = try store.read() { return key }
        throw MissingKey(name: openAIKeyName)
    }

    /// Whether a key is set, without reading it from the Keychain.
    public static func hasOpenAIAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        store: any SecretStore = openAIKeychain
    ) -> Bool {
        if let key = environment[openAIKeyName], !key.isEmpty { return true }
        return store.exists
    }

    /// Whether the key comes from the environment, which the menu can't change.
    public static func openAIKeyFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[openAIKeyName].map { !$0.isEmpty } ?? false
    }

    public struct MissingKey: Error, LocalizedError {
        let name: String
        public var errorDescription: String? {
            "No OpenAI key: set one with OpenAI Key in Yap's menu"
        }
    }

    public enum Migration: Equatable, Sendable {
        /// No file, or no key in it.
        case nothing
        /// The file's key is now in the Keychain.
        case imported
        /// The Keychain already had a key, which wins; the file's was dropped.
        case dropped
    }

    /// Moves `OPENAI_API_KEY` out of the old `secrets.env` into `store`, then
    /// takes it out of the file, and deletes the file if nothing else is left
    /// in it. A key already in `store` wins. If saving fails the file is left
    /// alone, so the next launch tries again.
    public static func migrateOpenAIKey(
        from file: URL = Paths.secretsFile,
        into store: any SecretStore = openAIKeychain
    ) throws -> Migration {
        guard let contents = try? String(contentsOf: file, encoding: .utf8),
            let key = parseDotEnv(contents)[openAIKeyName], !key.isEmpty
        else { return .nothing }

        let result: Migration
        if store.exists {
            result = .dropped
        } else {
            try store.save(key)
            result = .imported
        }

        let kept = contents.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { parseDotEnv(String($0))[openAIKeyName] == nil }
        let meaningful = kept.contains {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return !line.isEmpty && !line.hasPrefix("#")
        }
        if meaningful {
            try kept.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } else {
            try FileManager.default.removeItem(at: file)
        }
        return result
    }

    /// Minimal .env reader: `KEY=value`, `#` comments, optional surrounding quotes.
    static func parseDotEnv(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                let separator = line.firstIndex(of: "=")
            else { continue }

            let key = line[..<separator]
                .replacingOccurrences(of: "export ", with: "")
                .trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)

            if value.count >= 2,
                (value.hasPrefix("\"") && value.hasSuffix("\""))
                    || (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }
}
