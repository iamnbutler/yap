import Core
import Observation
import UIKit

/// What the keyboard knows of the app, and what its keys do.
@MainActor
@Observable
final class KeyboardModel {
    private(set) var state: Bridge.State?
    /// Whether the app has answered since this keyboard last pinged it. The
    /// state file alone can't say: a process that died leaves its last one.
    private(set) var appAnswered = false
    /// Something the keyboard itself has to say.
    private(set) var note: String?
    var returnTitle = "return"

    @ObservationIgnored private weak var controller: KeyboardViewController?
    @ObservationIgnored private var observer: Bridge.Observer?
    @ObservationIgnored private var pinged = Date.distantPast
    @ObservationIgnored private var waiting: Task<Void, Never>?
    @ObservationIgnored private var repeating: Task<Void, Never>?

    init(controller: KeyboardViewController) {
        self.controller = controller
    }

    var hasFullAccess: Bool { controller?.hasFullAccess ?? false }
    var needsGlobe: Bool { controller?.needsInputModeSwitchKey ?? true }

    /// The app's phase, or off when it isn't there to answer.
    var phase: Bridge.State.Phase {
        appAnswered ? state?.phase ?? .off : .off
    }

    func appear() {
        note = nil
        // Without Full Access the app group is out of reach, and with it
        // everything the keyboard could hear from the app.
        guard hasFullAccess else { return }
        Bridge.markKeyboardSeen()
        observer = Bridge.observe(.changed) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        pinged = .now
        appAnswered = false
        Bridge.post(.ping)
        refresh()
    }

    /// Stops listening while hidden, so a keyboard left open in another app
    /// can't claim text meant for this one.
    func disappear() {
        observer = nil
        waiting?.cancel()
        repeating?.cancel()
    }

    func refresh() {
        state = Bridge.State.read()
        if let state, state.updated >= pinged { appAnswered = true }
        while let result = Bridge.claim() {
            controller?.insert(result.text)
        }
    }

    // MARK: Keys

    func tapMicrophone() {
        note = nil
        guard hasFullAccess else {
            note = "Turn on Allow Full Access: Settings › Apps › Yap › Keyboards."
            return
        }
        switch phase {
        case .off:
            openApp()
        case .ready:
            Bridge.post(.start)
            // If the app has gone since it last answered, nothing will start,
            // and the only way to start it is to open it.
            waiting?.cancel()
            waiting = Task {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, self.phase == .ready else { return }
                self.openApp()
            }
        case .recording:
            Bridge.post(.stop)
        case .transcribing:
            break
        }
    }

    func cancel() {
        Bridge.post(.cancel)
    }

    func space() {
        controller?.textDocumentProxy.insertText(" ")
    }

    func enter() {
        controller?.textDocumentProxy.insertText("\n")
    }

    /// Deletes one character, then more and faster while held, like the
    /// system keyboard.
    func startDeleting() {
        guard repeating == nil else { return }
        controller?.textDocumentProxy.deleteBackward()
        repeating = Task {
            try? await Task.sleep(for: .milliseconds(450))
            var interval = 100
            while !Task.isCancelled {
                self.controller?.textDocumentProxy.deleteBackward()
                try? await Task.sleep(for: .milliseconds(interval))
                interval = max(40, interval - 5)
            }
        }
    }

    func stopDeleting() {
        repeating?.cancel()
        repeating = nil
    }

    private func openApp() {
        guard let view = controller?.view,
            HostApp.open(URL(string: "yap://dictate")!, from: view)
        else {
            note = "Open the Yap app to start a session, then come back."
            return
        }
    }
}
