import Foundation

/// One dictation, as it came back from the model.
public struct Transcript: Codable, Equatable, Sendable {
    public var date: Date
    public var text: String
    /// The app it was meant for.
    public var app: String?
    /// Whether it reached that app. False is the case this log exists for: a
    /// focus change or a refused activation used to lose the text outright.
    public var typed: Bool

    public init(date: Date = .now, text: String, app: String? = nil, typed: Bool = false) {
        self.date = date
        self.text = text
        self.app = app
        self.typed = typed
    }
}

/// Transcripts on disk: `transcripts/YYYY-MM-DD.jsonl`, one line each.
///
/// A file per day so that retention is deleting whole files, and JSON lines so
/// that a write is an append and a half-written line costs one entry.
public struct TranscriptLog: Sendable {
    public let directory: URL

    public static var defaultDirectory: URL {
        Paths.support.appendingPathComponent("transcripts", isDirectory: true)
    }

    public init(directory: URL = Self.defaultDirectory) {
        self.directory = directory
    }

    public func append(_ transcript: Transcript) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(Self.fileName(for: transcript.date))
        var line = try Self.encoder.encode(transcript)
        line.append(UInt8(ascii: "\n"))

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// The newest `limit` transcripts, newest first. Unreadable lines are
    /// skipped rather than failing the whole read.
    public func recent(_ limit: Int) -> [Transcript] {
        var found: [Transcript] = []
        for file in dayFiles().reversed() {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = contents.split(whereSeparator: \.isNewline).reversed()
            for line in lines {
                guard let transcript = try? Self.decoder.decode(Transcript.self, from: Data(line.utf8))
                else { continue }
                found.append(transcript)
                if found.count == limit { return found }
            }
        }
        return found
    }

    /// Deletes day files older than `days`, counting today as the first.
    public func prune(keepingDays days: Int, now: Date = .now) {
        guard days > 0 else { return }
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: now)
        else { return }
        let oldest = Self.fileName(for: calendar.startOfDay(for: cutoff))
        // The names sort as dates, so this is a string comparison.
        for file in dayFiles() where file.lastPathComponent < oldest {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Day files, oldest first.
    func dayFiles() -> [URL] {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func fileName(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.jsonl", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
