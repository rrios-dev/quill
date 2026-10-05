import AppCore
import AppKit
import Carbon.HIToolbox

/// The recorder's warning for system shortcuts (ARCHITECTURE §5.1): a built-in table of
/// macOS's default shortcuts plus the user's changes from `com.apple.symbolichotkeys`,
/// which stores only the entries the user changed, with Cocoa modifier masks. Quill-side:
/// no AppCore change.
struct SystemShortcuts {
    struct Shortcut: Equatable {
        var combination: KeyCombination
        /// A key of `Localizable.strings` naming what macOS does with it.
        var nameKey: String
    }

    /// Defaults by symbolic hot key id, so a user's change to one replaces it.
    static let defaults: [Int: Shortcut] = [
        7: .init(combination: .init(keyCode: UInt32(kVK_F2), modifiers: UInt32(controlKey)), nameKey: "system.menuBarFocus"),
        8: .init(combination: .init(keyCode: UInt32(kVK_F3), modifiers: UInt32(controlKey)), nameKey: "system.dockFocus"),
        27: .init(combination: .init(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(cmdKey)), nameKey: "system.nextWindow"),
        28: .init(combination: .init(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey)), nameKey: "system.screenshot"),
        29: .init(combination: .init(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey | controlKey)), nameKey: "system.screenshot"),
        30: .init(combination: .init(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey)), nameKey: "system.screenshot"),
        31: .init(combination: .init(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey | controlKey)), nameKey: "system.screenshot"),
        184: .init(combination: .init(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey)), nameKey: "system.screenshot"),
        32: .init(combination: .init(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(controlKey)), nameKey: "system.missionControl"),
        33: .init(combination: .init(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(controlKey)), nameKey: "system.appWindows"),
        36: .init(combination: .init(keyCode: UInt32(kVK_F11), modifiers: 0), nameKey: "system.showDesktop"),
        52: .init(combination: .init(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | optionKey)), nameKey: "system.dockHiding"),
        60: .init(combination: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey)), nameKey: "system.inputSource"),
        61: .init(combination: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)), nameKey: "system.inputSource"),
        64: .init(combination: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)), nameKey: "system.spotlight"),
        65: .init(combination: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey)), nameKey: "system.finderSearch"),
        79: .init(combination: .init(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(controlKey)), nameKey: "system.spaces"),
        81: .init(combination: .init(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(controlKey)), nameKey: "system.spaces"),
        98: .init(combination: .init(keyCode: UInt32(kVK_ANSI_Slash), modifiers: UInt32(cmdKey | shiftKey)), nameKey: "system.helpMenu"),
    ]

    /// Shortcuts macOS reserves that `com.apple.symbolichotkeys` does not list.
    static let fixed: [Shortcut] = [
        .init(combination: .init(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey)), nameKey: "system.appSwitcher"),
        .init(combination: .init(keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey | optionKey)), nameKey: "system.forceQuit"),
        .init(combination: .init(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey | controlKey)), nameKey: "system.lockScreen"),
        .init(combination: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | controlKey)), nameKey: "system.emoji"),
        .init(combination: .init(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey | shiftKey)), nameKey: "system.logOut"),
    ]

    private let active: [Shortcut]

    /// `overrides` is `AppleSymbolicHotKeys` as `com.apple.symbolichotkeys` stores it.
    init(overrides: [String: Any]) {
        var byID = Self.defaults
        for (key, value) in overrides {
            guard let id = Int(key), let entry = value as? [String: Any] else { continue }
            // Stored as a number (0 or 1); a property list may also hold a boolean.
            let enabled = (entry["enabled"] as? NSNumber)?.boolValue ?? true
            guard enabled else { byID[id] = nil; continue }
            guard let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count == 3,
                  parameters[1] != 65_535 else { continue }
            let name = byID[id]?.nameKey ?? "system.other"
            byID[id] = Shortcut(combination: KeyCombination(keyCode: UInt32(parameters[1]),
                                                            modifiers: Self.carbonModifiers(cocoa: parameters[2])),
                                nameKey: name)
        }
        active = Array(byID.values) + Self.fixed
    }

    /// The user's own table.
    static func live() -> SystemShortcuts {
        let overrides = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        return SystemShortcuts(overrides: overrides)
    }

    /// What macOS does with `combination`, if anything.
    func conflict(for combination: KeyCombination) -> Shortcut? {
        let relevant = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        return active.first {
            $0.combination.keyCode == combination.keyCode && $0.combination.modifiers & relevant == combination.modifiers & relevant
        }
    }

    /// Cocoa's modifier mask (as stored) to Carbon's (as registered); the function-key and
    /// numeric-pad bits macOS adds to arrows and F-keys are dropped.
    static func carbonModifiers(cocoa: Int) -> UInt32 {
        var carbon = 0
        if cocoa & Int(NSEvent.ModifierFlags.shift.rawValue) != 0 { carbon |= shiftKey }
        if cocoa & Int(NSEvent.ModifierFlags.control.rawValue) != 0 { carbon |= controlKey }
        if cocoa & Int(NSEvent.ModifierFlags.option.rawValue) != 0 { carbon |= optionKey }
        if cocoa & Int(NSEvent.ModifierFlags.command.rawValue) != 0 { carbon |= cmdKey }
        return UInt32(carbon)
    }
}
