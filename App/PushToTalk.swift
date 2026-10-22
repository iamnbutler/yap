import AppKit

/// Watches Right Command: press, release, and whether another key went down
/// while it was held.
///
/// A bare modifier rather than a chord, so holding it costs nothing, and Right
/// Command rather than Right Option, which Hob uses. Another key during the
/// hold means it was a shortcut (Right Command-Tab, say), reported through
/// `onChord` so the caller can drop it.
@MainActor
final class PushToTalk {
    static let rightCommandKeyCode: UInt16 = 54

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

        let flags: (NSEvent) -> Void = { [weak self] in self?.handle($0) }
        let keys: (NSEvent) -> Void = { [weak self] _ in
            guard let self, self.isDown else { return }
            self.onChord?()
        }
        // Local monitors too, so the key also works while Yap's menu is open.
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: flags),
            NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { flags($0); return $0 },
            NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: keys),
            NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { keys($0); return $0 },
        ].compactMap { $0 }
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == Self.rightCommandKeyCode else { return }

        // flagsChanged fires for both press and release; the flag tells us which.
        let pressed = event.modifierFlags.contains(.command)
        guard pressed != isDown else { return }
        isDown = pressed
        pressed ? onDown?() : onUp?()
    }
}
