import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Modifier keys physically held.
public struct HeldModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = HeldModifiers(rawValue: 1 << 0)
    public static let control = HeldModifiers(rawValue: 1 << 1)
    public static let option = HeldModifiers(rawValue: 1 << 2)
    public static let command = HeldModifiers(rawValue: 1 << 3)
}

/// Synthetic keyboard events and key state, behind a seam (ARCHITECTURE §3.7). No test
/// ever posts a real key: tests use a fake.
public protocol KeyEventPoster: Sendable {
    /// Posts ⌘ + the key that types `letter` in the current layout, with flags forced
    /// to exactly ⌘. Returns false when the event could not be built or posted.
    func postCommandShortcut(_ letter: Character) async -> Bool
    func isKeyDown(_ keyCode: CGKeyCode) -> Bool
    func heldModifiers() -> HeldModifiers
}

/// Where key codes come from: the current layout and the ASCII-capable one, each asked
/// for the key that types a letter **with ⌘ held**. A seam, so tests drive each case.
public protocol KeyboardLayoutSource: Sendable {
    func currentLayoutKeyCode(for letter: Character) async -> CGKeyCode?
    func asciiCapableLayoutKeyCode(for letter: Character) async -> CGKeyCode?
}

/// The Text Input Sources answer (on the main thread).
public struct LiveKeyboardLayoutSource: KeyboardLayoutSource {
    public init() {}

    public func currentLayoutKeyCode(for letter: Character) async -> CGKeyCode? {
        await MainActor.run { KeyboardLayout.keyCode(for: letter, in: TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()) }
    }

    public func asciiCapableLayoutKeyCode(for letter: Character) async -> CGKeyCode? {
        await MainActor.run { KeyboardLayout.keyCode(for: letter, in: TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()) }
    }
}

/// Posts its own events through the HID event tap, the way `AppCore.Paster` does —
/// `Paster` hard-codes `kVK_ANSI_V` and has no ⌘C, so it is not called directly.
public struct LiveKeyEventPoster: KeyEventPoster {
    let layout: any KeyboardLayoutSource

    public init(layout: any KeyboardLayoutSource = LiveKeyboardLayoutSource()) {
        self.layout = layout
    }

    public func postCommandShortcut(_ letter: Character) async -> Bool {
        let keyCode = await KeyboardLayout.commandKeyCode(for: letter, source: layout)
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        // Assigning `flags` replaces the inherited state: a ⌃⌥ still held from the
        // trigger would otherwise turn ⌘C into ⌃⌥⌘C in the host.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Physical key state (`hidSystemState`): the combined session state also counts
    /// synthetic events, so a ⌘ another process — or Quill — just posted would read as held.
    public func isKeyDown(_ keyCode: CGKeyCode) -> Bool {
        CGEventSource.keyState(.hidSystemState, key: keyCode)
    }

    public func heldModifiers() -> HeldModifiers {
        let flags = CGEventSource.flagsState(.hidSystemState)
        var held: HeldModifiers = []
        if flags.contains(.maskShift) { held.insert(.shift) }
        if flags.contains(.maskControl) { held.insert(.control) }
        if flags.contains(.maskAlternate) { held.insert(.option) }
        if flags.contains(.maskCommand) { held.insert(.command) }
        return held
    }
}

/// Finds the key code that produces a letter **with ⌘ held** in the current keyboard
/// layout (ARCHITECTURE §3.2 step 7).
///
/// On "Dvorak – QWERTY ⌘" the ⌘ layer differs from the plain one, so the lookup
/// translates with the command modifier state. When no key yields the letter
/// (Cyrillic, Greek), the ASCII-capable layout is tried, then the ANSI code.
public enum KeyboardLayout {
    /// The current layout's ⌘ key for `letter`, else the ASCII-capable layout's, else ANSI.
    public static func commandKeyCode(for letter: Character, source: any KeyboardLayoutSource) async -> CGKeyCode {
        if let code = await source.currentLayoutKeyCode(for: letter) { return code }
        if let code = await source.asciiCapableLayoutKeyCode(for: letter) { return code }
        return ansiKeyCode(for: letter)
    }

    /// Text Input Sources calls run on the main thread.
    @MainActor
    static func keyCode(for letter: Character, in source: TISInputSource?) -> CGKeyCode? {
        guard let source else { return nil }
        return keyCode(producing: String(letter).lowercased(), in: source)
    }

    /// The US ANSI position of a letter, the last resort.
    public static func ansiKeyCode(for letter: Character) -> CGKeyCode {
        switch String(letter).lowercased() {
        case "c": CGKeyCode(kVK_ANSI_C)
        case "v": CGKeyCode(kVK_ANSI_V)
        case "x": CGKeyCode(kVK_ANSI_X)
        case "a": CGKeyCode(kVK_ANSI_A)
        default: CGKeyCode(kVK_ANSI_V)
        }
    }

    @MainActor
    private static func keyCode(producing target: String, in source: TISInputSource) -> CGKeyCode? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        // UCKeyTranslate takes the Carbon modifier bits shifted right by 8.
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        let keyboardType = UInt32(LMGetKbdType())
        return layoutData.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<UInt16(128) {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), commandState, keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                    characters.count, &length, &characters
                )
                guard status == noErr, length > 0 else { continue }
                if String(utf16CodeUnits: characters, count: length).lowercased() == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
