import Foundation

/// Resolves the OpenAI key on the Mac: the environment, then the login
/// Keychain, then `secrets.env`.
///
/// The Keychain item is the one `security` reads: service `OPENAI_API_KEY`,
/// account the user name. A Yap started at login by launchd has no shell, so
/// no environment key, and the Keychain is where it finds one. The item made
/// by `security` lists only `security` as allowed to read it, so macOS asks
/// once whether Yap may; Always Allow adds Yap, keyed on its signing
/// certificate, which a rebuild keeps. `secrets.env` stays for setups that
/// already use it.
public enum Secrets {
    public static let name = "OPENAI_API_KEY"

    /// The login Keychain item that holds the key.
    public static var keychainItem: KeychainItem {
        KeychainItem(service: name, account: NSUserName())
    }

    public static func openAIAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychain: () -> KeychainItem.Lookup = { keychainItem.lookup() },
        file: URL = Paths.secretsFile
    ) throws -> String {
        if let key = environment[name], !key.isEmpty { return key }
        let fromKeychain = keychain()
        if case .found(let key) = fromKeychain { return key }
        if let key = fromFile(file) { return key }
        throw MissingKey(item: keychainItem, file: file, denied: fromKeychain == .denied)
    }

    /// Whether a key is set anywhere, without reading the Keychain's secret,
    /// so polling this never raises the Keychain prompt.
    public static func hasOpenAIAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychain: () -> Bool = { keychainItem.exists },
        file: URL = Paths.secretsFile
    ) -> Bool {
        if let key = environment[name], !key.isEmpty { return true }
        return keychain() || fromFile(file) != nil
    }

    private static func fromFile(_ file: URL) -> String? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8),
            let key = parseDotEnv(contents)[name], !key.isEmpty
        else { return nil }
        return key
    }

    public struct MissingKey: Error, LocalizedError {
        let item: KeychainItem
        let file: URL
        let denied: Bool

        public var errorDescription: String? {
            let keychain = "the login Keychain (service \(item.service), account \(item.account))"
            if denied {
                return "Yap isn't allowed to read \(keychain). Choose Always Allow when macOS asks, "
                    + "or add Yap under the item's Access Control in Keychain Access."
            }
            return "No \(item.service) in the environment, \(keychain) or \(file.path). "
                + "Set it with Set OpenAI Key… in the menu; macOS asks once whether Yap may use it: choose Always Allow."
        }
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
