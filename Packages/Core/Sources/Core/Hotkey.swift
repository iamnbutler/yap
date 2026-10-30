import Foundation

/// The key you hold or tap to dictate, as written in config.json: a bare
/// modifier ("rightCommand", "leftOption", "fn"), an ordinary key ("f13"), or
/// any key by its code ("keycode:105").
///
/// Names are matched ignoring case, spaces, dashes and underscores, so
/// "Right Command", "right-command" and "rightcommand" are the same key.
public struct Hotkey: Equatable, Sendable {
    /// The virtual key code macOS reports for it.
    public let keyCode: UInt16
    /// For a modifier, the bit it sets in `NSEvent.ModifierFlags`'s raw value:
    /// how a press is told from a release. The bit for that side of the
    /// keyboard, not the shared Command or Option flag, which stays set while
    /// the other side's key is held. Nil for an ordinary key, which has key
    /// down and key up events instead.
    public let modifierFlag: UInt?
    /// For the menu and status text: "Right Command", "F13".
    public let name: String

    public var isModifier: Bool { modifierFlag != nil }

    public static let rightCommand = Hotkey(keyCode: 54, modifierFlag: rightCommandMask, name: "Right Command")

    // IOKit's NX_DEVICE*KEYMASK values, which NSEvent keeps in the low bits
    // of its modifier flags. fn has no sides, so it uses its own flag.
    private static let leftControlMask: UInt = 0x0001
    private static let leftShiftMask: UInt = 0x0002
    private static let rightShiftMask: UInt = 0x0004
    private static let leftCommandMask: UInt = 0x0008
    private static let rightCommandMask: UInt = 0x0010
    private static let leftOptionMask: UInt = 0x0020
    private static let rightOptionMask: UInt = 0x0040
    private static let rightControlMask: UInt = 0x2000
    private static let function: UInt = 1 << 23

    private static let modifiers: [String: Hotkey] = {
        let keys = [
            rightCommand,
            Hotkey(keyCode: 55, modifierFlag: leftCommandMask, name: "Left Command"),
            Hotkey(keyCode: 61, modifierFlag: rightOptionMask, name: "Right Option"),
            Hotkey(keyCode: 58, modifierFlag: leftOptionMask, name: "Left Option"),
            Hotkey(keyCode: 62, modifierFlag: rightControlMask, name: "Right Control"),
            Hotkey(keyCode: 59, modifierFlag: leftControlMask, name: "Left Control"),
            Hotkey(keyCode: 60, modifierFlag: rightShiftMask, name: "Right Shift"),
            Hotkey(keyCode: 56, modifierFlag: leftShiftMask, name: "Left Shift"),
            Hotkey(keyCode: 63, modifierFlag: function, name: "fn"),
        ]
        var byName: [String: Hotkey] = [:]
        for key in keys {
            byName[normalize(key.name)] = key
        }
        // What people tend to write instead.
        let aliases = [
            "rightcmd": "rightcommand", "rcmd": "rightcommand",
            "leftcmd": "leftcommand", "lcmd": "leftcommand",
            "rightalt": "rightoption", "ralt": "rightoption", "ropt": "rightoption",
            "leftalt": "leftoption", "lalt": "leftoption", "lopt": "leftoption",
            "rightctrl": "rightcontrol", "rctrl": "rightcontrol",
            "leftctrl": "leftcontrol", "lctrl": "leftcontrol",
            "rshift": "rightshift", "lshift": "leftshift",
            "function": "fn", "globe": "fn",
        ]
        for (alias, name) in aliases {
            byName[alias] = byName[name]
        }
        return byName
    }()

    /// F1 to F20. Their codes follow no pattern.
    private static let functionKeys: [UInt16] = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    public init(keyCode: UInt16, modifierFlag: UInt? = nil, name: String) {
        self.keyCode = keyCode
        self.modifierFlag = modifierFlag
        self.name = name
    }

    /// Nil for a name it does not know.
    public init?(_ text: String) {
        let key = Self.normalize(text)
        if let modifier = Self.modifiers[key] {
            self = modifier
        } else if key.hasPrefix("f"), let number = Int(key.dropFirst()),
            (1...Self.functionKeys.count).contains(number)
        {
            self.init(keyCode: Self.functionKeys[number - 1], name: "F\(number)")
        } else if key.hasPrefix("keycode:"), let code = UInt16(key.dropFirst("keycode:".count)) {
            // A modifier's code still behaves as that modifier.
            self = Self.modifiers.values.first { $0.keyCode == code }
                ?? Hotkey(keyCode: code, name: "Key \(code)")
        } else {
            return nil
        }
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { !" -_".contains($0) }
    }
}
