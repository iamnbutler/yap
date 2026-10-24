import Foundation

/// Settings you can edit by hand: `config.json` in the support directory.
///
///     {
///       "key": "rightCommand",
///       "keepTranscripts": true,
///       "overlay": true,
///       "retentionDays": 30,
///       "engine": "onDevice",
///       "refine": true
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
    /// The key to hold or tap, by name: see `Hotkey`. Kept as written, so a
    /// name Yap does not know survives a save from the menu and can be fixed.
    public var key = "rightCommand"
    /// Who transcribes: `onDevice` (Apple's model, free and private) or
    /// `openAI` (better with jargon, with your key). Either falls back to the
    /// other when it fails and the other can run.
    public var engine = Engine.onDevice
    /// Clean up on-device transcripts with Apple Intelligence: punctuation,
    /// filler words, false starts. OpenAI's transcripts don't need it.
    public var refine = true

    public enum Engine: String, Codable, Sendable, CaseIterable {
        case onDevice, openAI
    }

    /// `key` as a key, or nil when the name is not one Yap knows.
    public var hotkey: Hotkey? { Hotkey(key) }

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
        key =
            try container.decodeIfPresent(String.self, forKey: .key)
            ?? defaults.key
        // An engine this version doesn't know falls back, rather than
        // failing the whole file.
        engine =
            (try? container.decodeIfPresent(Engine.self, forKey: .engine))
            .flatMap { $0 } ?? defaults.engine
        refine =
            try container.decodeIfPresent(Bool.self, forKey: .refine)
            ?? defaults.refine
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
