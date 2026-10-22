import AppKit
import Core

/// Watches the dictation key: press, release, and whether another key went
/// down while it was held.
///
/// Right Command unless config.json says otherwise. A bare modifier by
/// default, so holding it costs nothing; another key during the hold means it
/// was a shortcut (Right Command-Tab, say), reported through `onChord` so the
/// caller can drop it.
///
/// An ordinary key (F13, say) works too, but a global monitor only listens:
/// the key still reaches the app in front. Pick one that does nothing there.
@MainActor
final class PushToTalk {
    var hotkey = Hotkey.rightCommand {
        didSet {
            // Mid-hold, the old key's release would never be heard.
            if hotkey != oldValue, isDown {
                isDown = false
                onUp?()
            }
        }
    }

    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onChord: (() -> Void)?

    private var monitors: [Any] = []
    private var isDown = false

    /// Global key monitoring requires Accessibility. Prompts once if not granted.
    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool = true) -> Bool {
        // The kAXTrustedCheckOptionPrompt global is not concurrency-safe under
        // Swift 6; its value is this literal.
        let options = ["AXTrustedCheckOptionPrompt": prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func start() {
        guard monitors.isEmpty else { return }

        let handler: (NSEvent) -> Void = { [weak self] in self?.handle($0) }
        let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        // Local monitors too, so the key also works while Yap's menu is open.
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: events, handler: handler),
            NSEvent.addLocalMonitorForEvents(matching: events) { handler($0); return $0 },
        ].compactMap { $0 }
    }

    private func handle(_ event: NSEvent) {
        let ours = event.keyCode == hotkey.keyCode
        switch event.type {
        case .flagsChanged:
            guard ours, let flag = hotkey.modifierFlag else { return }
            // flagsChanged fires for both press and release; the flag tells us which.
            set(down: event.modifierFlags.rawValue & flag != 0)
        case .keyDown where ours && !hotkey.isModifier:
            // Holding a key repeats key down; only the first one is a press.
            guard !event.isARepeat else { return }
            set(down: true)
        case .keyUp where ours && !hotkey.isModifier:
            set(down: false)
        case .keyDown where isDown:
            onChord?()
        default:
            break
        }
    }

    private func set(down: Bool) {
        guard down != isDown else { return }
        isDown = down
        down ? onDown?() : onUp?()
    }
}
