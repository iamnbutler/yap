import AppKit
import ApplicationServices

/// Types into another application, as if the user had typed it themselves.
///
/// Synthesized key events rather than Accessibility or the pasteboard, because
/// this has to work in a terminal. `AXValue` on a terminal's text area is the
/// scrollback, not an input line, and setting it is meaningless; the pasteboard
/// would clobber whatever the user had copied. A key event is the one thing
/// every app already accepts.
enum TextInjector {
    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Each event carries a bounded run of UTF-16 units. Long strings are split
    /// rather than sent as one event: the payload is a fixed-size buffer.
    private static let unitsPerEvent = 20

    /// A pause between events, so a terminal's input handling keeps up. Chosen
    /// low enough that a sentence still lands in well under a tenth of a
    /// second — 64 characters measured at 69ms end to end.
    private static let pauseBetweenEvents: useconds_t = 4000

    private static let returnKey: CGKeyCode = 36

    /// How long to wait for the target app to come forward before typing.
    private static let activationTimeout = 0.6

    /// Types `text` into `pid`, optionally pressing Return afterwards.
    ///
    /// Brings the target forward first and confirms it got there. Typing into
    /// whatever happens to be frontmost would put the user's words in the wrong
    /// window, which is worse than not typing at all.
    @MainActor
    static func type(_ text: String, into pid: pid_t, submit: Bool) async throws {
        guard !text.isEmpty else { throw Failure(reason: "nothing to type") }
        guard AXIsProcessTrusted() else {
            throw Failure(reason: "Accessibility is not granted, so Yap cannot type")
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            throw Failure(reason: "that app is no longer running")
        }

        try await activate(app)

        // Off the main actor: the burst sleeps between events, and the main
        // actor is where the push-to-talk monitor lives. A long line would
        // otherwise hold the hotkey down for its own duration.
        let runs = runs(of: text)
        await Task.detached(priority: .userInitiated) {
            // One source for the whole burst so the events share a state —
            // separate sources can interleave a stale modifier state.
            let source = CGEventSource(stateID: .hidSystemState)
            for run in runs { post(run, from: source) }
            if submit { press(returnKey, from: source) }
        }.value
    }

    @MainActor
    private static func activate(_ app: NSRunningApplication) async throws {
        if !app.isActive {
            app.activate()
            let deadline = Date().addingTimeInterval(activationTimeout)
            while !app.isActive, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        guard app.isActive else {
            throw Failure(
                reason: "\(app.localizedName ?? "that app") would not come to the front")
        }
    }

    /// The text split into per-event payloads, never through the middle of a
    /// surrogate pair — half an emoji is not a character.
    private static func runs(of text: String) -> [[UniChar]] {
        var runs: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(character.utf16)
            if current.count + units.count > unitsPerEvent, !current.isEmpty {
                runs.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Posts one run as a key down/up pair.
    ///
    /// The virtual key code is 0 and the payload is the unicode string, so what
    /// arrives is the characters themselves rather than whatever key 0 means
    /// under the user's keyboard layout.
    private static func post(_ units: [UniChar], from source: CGEventSource?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        usleep(pauseBetweenEvents)
    }

    private static func press(_ key: CGKeyCode, from source: CGEventSource?) {
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?
            .post(tap: .cghidEventTap)
    }
}
