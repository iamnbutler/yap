import Foundation
import notify

/// How Yap's iOS keyboard and app talk to each other.
///
/// iOS gives a keyboard extension no microphone, so the app records and the
/// keyboard only asks it to. Asking needs the app running already: it can
/// keep recording in the background, but iOS won't let it start from there.
/// So the app holds the microphone open for a session, dropping audio between
/// dictations, and the keyboard opens the app to start one when there is none.
///
/// Darwin notifications carry the asks, and "something changed" back. They
/// carry no data and reach only a running process, so they are hints. What is
/// true is in files in the app group: `state.json`, which only the app writes,
/// and a file per transcript waiting for a keyboard to insert it.
public enum Bridge {
    public enum Signal: String, Sendable, CaseIterable {
        /// Keyboard to app.
        case start, stop, cancel, ping
        /// App to keyboard: `state.json` or the waiting transcripts changed.
        case changed

        var name: String { "dev.yap.Yap.bridge.\(rawValue)" }
    }

    public static var directory: URL {
        Paths.support.appendingPathComponent("bridge", isDirectory: true)
    }

    /// Text older than this is never inserted. It was dictated for whatever
    /// field was in front then, not the one in front now; it is still in the
    /// app's transcripts.
    public static let resultLifetime: TimeInterval = 120

    public static func post(_ signal: Signal) {
        notify_post(signal.name)
    }

    /// Calls `handler` on `queue` each time `signal` is posted, for as long as
    /// the returned observer lives.
    public static func observe(
        _ signal: Signal, queue: DispatchQueue = .main,
        handler: @escaping @Sendable () -> Void
    ) -> Observer {
        var token: Int32 = 0
        notify_register_dispatch(signal.name, &token, queue) { _ in handler() }
        return Observer(token: token)
    }

    public final class Observer: Sendable {
        private let token: Int32

        init(token: Int32) {
            self.token = token
        }

        deinit {
            notify_cancel(token)
        }
    }

    /// The app's side of things, as the keyboard should show it.
    public struct State: Codable, Equatable, Sendable {
        public enum Phase: String, Codable, Sendable {
            /// No session: the microphone is closed, and the keyboard has to
            /// open the app to dictate.
            case off
            /// The microphone is open and dropping audio until asked to start.
            case ready
            case recording
            case transcribing
        }

        public var phase: Phase
        /// What has been heard so far while recording.
        public var preview: String
        /// The last thing worth saying: an error, or "Heard nothing".
        public var message: String?
        /// When the session ends by itself.
        public var expires: Date?
        /// When the app last wrote this. A ping bumps it, so a keyboard can
        /// tell an app that answers from a file left behind by one that died.
        public var updated: Date

        public init(
            phase: Phase = .off, preview: String = "", message: String? = nil,
            expires: Date? = nil, updated: Date = .now
        ) {
            self.phase = phase
            self.preview = preview
            self.message = message
            self.expires = expires
            self.updated = updated
        }

        public static func read(from directory: URL = Bridge.directory) -> State? {
            guard let data = try? Data(contentsOf: file(in: directory)) else { return nil }
            return try? Bridge.decoder.decode(State.self, from: data)
        }

        public func write(to directory: URL = Bridge.directory) throws {
            try Bridge.prepare(directory)
            try Bridge.encoder.encode(self).write(to: Self.file(in: directory), options: .atomic)
        }

        static func file(in directory: URL) -> URL {
            directory.appendingPathComponent("state.json")
        }
    }

    /// A transcript waiting for a keyboard to insert it.
    public struct Result: Codable, Equatable, Sendable {
        public var id: UUID
        public var text: String
        public var date: Date

        public init(id: UUID = UUID(), text: String, date: Date = .now) {
            self.id = id
            self.text = text
            self.date = date
        }
    }

    /// Leaves `text` for the keyboard. Written whole and then renamed into
    /// place, so a keyboard never reads half of one.
    public static func deliver(_ result: Result, in directory: URL = directory) throws {
        let results = directory.appendingPathComponent("results", isDirectory: true)
        try prepare(results)
        let name = String(format: "%.0f", result.date.timeIntervalSince1970 * 1000)
            + "-\(result.id.uuidString).json"
        try encoder.encode(result).write(to: results.appendingPathComponent(name), options: .atomic)
    }

    /// Takes the oldest waiting transcript, so it is inserted once however many
    /// keyboards are open: every app with a text field has its own, and they
    /// all hear the same notification. The rename is the claim; only one
    /// keyboard's can succeed. Results past `resultLifetime` are deleted
    /// unread.
    public static func claim(in directory: URL = directory, now: Date = .now) -> Result? {
        let results = directory.appendingPathComponent("results", isDirectory: true)
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: results, includingPropertiesForKeys: nil)) ?? []
        // The names start with the time in milliseconds, so they sort by age.
        let waiting = files
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in waiting {
            let claimed = results.appendingPathComponent(".claimed-\(UUID().uuidString)")
            guard (try? FileManager.default.moveItem(at: file, to: claimed)) != nil else { continue }
            defer { try? FileManager.default.removeItem(at: claimed) }
            guard let data = try? Data(contentsOf: claimed),
                let result = try? decoder.decode(Result.self, from: data),
                now.timeIntervalSince(result.date) < resultLifetime
            else { continue }
            return result
        }
        return nil
    }

    /// Written by the keyboard each time it opens. It can only reach the app
    /// group with Full Access, so the file existing tells the app that the
    /// keyboard is installed and allowed.
    public static func markKeyboardSeen(in directory: URL = directory, now: Date = .now) {
        try? prepare(directory)
        try? encoder.encode(now).write(
            to: directory.appendingPathComponent("keyboard.json"), options: .atomic)
    }

    public static func keyboardSeen(in directory: URL = directory) -> Date? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("keyboard.json"))
        else { return nil }
        return try? decoder.decode(Date.self, from: data)
    }

    private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
