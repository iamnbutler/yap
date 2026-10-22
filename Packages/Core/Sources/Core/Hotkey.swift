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
    /// For a modifier, the `NSEvent.ModifierFlags` raw value it sets: how a
    /// press is told from a release. Nil for an ordinary key, which has key
    /// down and key up events instead.
    public let modifierFlag: UInt?
    /// For the menu and status text: "Right Command", "F13".
    public let name: String

    public var isModifier: Bool { modifierFlag != nil }

    public static let rightCommand = Hotkey(keyCode: 54, modifierFlag: command, name: "Right Command")

    // NSEvent.ModifierFlags raw values, so Core needs no AppKit.
    private static let shift: UInt = 1 << 17
    private static let control: UInt = 1 << 18
    private static let option: UInt = 1 << 19
    private static let command: UInt = 1 << 20
    private static let function: UInt = 1 << 23

    private static let modifiers: [String: Hotkey] = {
        let keys = [
            Hotkey(keyCode: 54, modifierFlag: command, name: "Right Command"),
            Hotkey(keyCode: 55, modifierFlag: command, name: "Left Command"),
            Hotkey(keyCode: 61, modifierFlag: option, name: "Right Option"),
            Hotkey(keyCode: 58, modifierFlag: option, name: "Left Option"),
            Hotkey(keyCode: 62, modifierFlag: control, name: "Right Control"),
            Hotkey(keyCode: 59, modifierFlag: control, name: "Left Control"),
            Hotkey(keyCode: 60, modifierFlag: shift, name: "Right Shift"),
            Hotkey(keyCode: 56, modifierFlag: shift, name: "Left Shift"),
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
