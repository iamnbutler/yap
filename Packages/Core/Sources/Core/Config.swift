import Foundation

/// Settings you can edit by hand: `config.json` in the support directory.
///
///     {
///       "keepTranscripts": true,
///       "overlay": true,
///       "retentionDays": 30
///     }
///
/// A missing file or a missing key falls back to its default, so the file
/// only needs what you want to change. The menu's checkboxes write here too.
public struct Config: Codable, Equatable, Sendable {
    /// Save every transcript to disk, one JSON-lines file per day. Without it,
    /// only the last few live in memory and are gone on quit.
    public var keepTranscripts = true
    /// Days of transcript files to keep; older ones are deleted.
    public var retentionDays = 30
    /// Show what is being heard while you talk, in a panel at the bottom of
    /// the screen. Each pause sends the last phrase for transcription, so this
    /// roughly doubles the audio sent to OpenAI.
    public var overlay = true

    public static var file: URL {
        Paths.support.appendingPathComponent("config.json")
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        keepTranscripts =
            try container.decodeIfPresent(Bool.self, forKey: .keepTranscripts)
            ?? defaults.keepTranscripts
        retentionDays =
            try container.decodeIfPresent(Int.self, forKey: .retentionDays)
            ?? defaults.retentionDays
        overlay =
            try container.decodeIfPresent(Bool.self, forKey: .overlay)
            ?? defaults.overlay
    }

    /// The file's settings, or the defaults when it is missing. A file that
    /// will not parse is reported rather than silently replaced, since it is
    /// one you were editing.
    public static func load(from url: URL = file) throws -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        return try JSONDecoder().decode(Config.self, from: data)
    }

    public func save(to url: URL = file) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
