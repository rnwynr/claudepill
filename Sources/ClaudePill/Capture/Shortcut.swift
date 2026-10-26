import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut, stored in the form Carbon's `RegisterEventHotKey` wants.
struct Shortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    /// Human-readable key, captured when the shortcut was recorded.
    var keyLabel: String

    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }

    /// Returns nil for combos that make bad global shortcuts (plain letters, Shift+letter).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = Int(event.keyCode)
        let isFunctionKey = Self.functionKeys.contains(code)
        let hasStrongModifier = !flags.intersection([.command, .control, .option]).isEmpty
        guard hasStrongModifier || isFunctionKey else { return nil }

        let label = Self.specialKeyLabels[code]
            ?? event.characters(byApplyingModifiers: [])?.uppercased()
            ?? ""
        guard !label.isEmpty, !label.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        self.init(keyCode: UInt32(code), carbonModifiers: Self.carbonFlags(flags), keyLabel: label)
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    static func carbonFlags(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let specialKeyLabels: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}

extension CaptureAction {
    /// ⌥⇧1 / ⌥⇧2 / ⌥⇧3 — stays clear of the system's ⌘⇧3/4/5.
    var defaultShortcut: Shortcut {
        let mods = UInt32(optionKey | shiftKey)
        switch self {
        case .screenshotToClipboard: return Shortcut(keyCode: UInt32(kVK_ANSI_1), carbonModifiers: mods, keyLabel: "1")
        case .screenshotToFile: return Shortcut(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: mods, keyLabel: "2")
        case .record: return Shortcut(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: mods, keyLabel: "3")
        }
    }

    static var defaultShortcuts: [CaptureAction: Shortcut] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.defaultShortcut) })
    }
}
