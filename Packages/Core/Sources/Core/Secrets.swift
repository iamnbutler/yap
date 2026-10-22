import Foundation

/// Resolves the OpenAI key: the environment, then `secrets.env`.
///
/// Not the Keychain, and not 1Password: a Keychain item made by Keychain Access
/// raises a prompt for every rebuilt signature, and `op` raises one per read.
/// A mode-600 file in a 700 directory is the right trade for one machine.
public enum Secrets {
    public static func openAIAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        file: URL = Paths.secretsFile
    ) throws -> String {
        let name = "OPENAI_API_KEY"
        if let key = environment[name], !key.isEmpty { return key }
        if let contents = try? String(contentsOf: file, encoding: .utf8),
            let key = parseDotEnv(contents)[name], !key.isEmpty
        {
            return key
        }
        throw MissingKey(name: name, file: file)
    }

    public struct MissingKey: Error, LocalizedError {
        let name: String
        let file: URL
        public var errorDescription: String? { "No \(name) in the environment or \(file.path)" }
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
