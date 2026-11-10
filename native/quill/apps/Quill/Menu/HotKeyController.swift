import AppKit
import AppCore
import Carbon.HIToolbox
import RemoteTyping
import RewriteKit

/// The global shortcut, registered **exclusively** (ARCHITECTURE §5.1): a combination
/// another app holds exclusively is reported, never retried as a shared registration,
/// which would return no error and never fire.
@MainActor
final class HotKeyController {
    enum State: Equatable {
        case unregistered
        case registered(KeyCombination)
        /// Another app holds it exclusively.
        case inUse(KeyCombination)
        case failed(KeyCombination, OSStatus)
    }

    /// ⌃⌥R (README Q4): two modifiers and R for "rewrite", free of macOS's shortcuts;
    /// ⌥⌘R and ⇧⌘R are Safari's.
    static let defaultShortcut = KeyCombination(
        keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey))
    /// Registers a combination with what its press and its release do. The release lets
    /// the same shortcut tell a tap (rewrite) from a hold (dictate, EFFICIENCY.md E8).
    typealias Register = @MainActor (KeyCombination, @escaping () -> Void, (() -> Void)?) -> Result<UInt32, HotKeyRegistrationError>
    typealias Unregister = @MainActor (UInt32) -> Void

    private(set) var state: State = .unregistered
    private var identifier: UInt32?
    private let registerExclusive: Register
    private let unregister: Unregister

    init(
        register: @escaping Register = { HotKeyCenter.shared.register($0, options: .exclusive, action: $1, onRelease: $2) },
        unregister: @escaping Unregister = { HotKeyCenter.shared.unregister($0) }
    ) {
        self.registerExclusive = register
        self.unregister = unregister
    }

    /// Replaces the current registration with `combination`.
    func register(_ combination: KeyCombination, action: @escaping () -> Void, onRelease: (() -> Void)? = nil) {
        if let identifier { unregister(identifier) }
        identifier = nil
        switch registerExclusive(combination, action, onRelease) {
        case .success(let id):
            identifier = id
            state = .registered(combination)
        case .failure(let error) where error.isInUseByAnotherApp:
            state = .inUse(combination)
        case .failure(let error):
            state = .failed(combination, error.status)
        }
    }

    /// A line for the menu when the shortcut does not work; nil when it does.
    var problem: String? {
        switch state {
        case .unregistered, .registered: nil
        case .inUse(let combination):
            String(localized: "menu.shortcut.inUse \(combination.displayString)", bundle: .localized)
        case .failed(let combination, _):
            String(localized: "menu.shortcut.failed \(combination.displayString)", bundle: .localized)
        }
    }

    var combination: KeyCombination? {
        switch state {
        case .unregistered: nil
        case .registered(let combination), .inUse(let combination), .failed(let combination, _): combination
        }
    }

    /// The shortcuts Batuta is asked to keep on the Mac while another computer has the
    /// keyboard (shared-control S6 R6): only one Quill holds, since one that did not register
    /// would never fire, and keeping it would only take it from the other computer's apps.
    var reservedChords: [RemoteChord] {
        guard case .registered(let combination) = state else { return [] }
        return [RemoteChord(combination)]
    }
}

extension KeyCombination {
    init(_ stored: StoredShortcut) { self.init(keyCode: stored.keyCode, modifiers: stored.modifiers) }
}

extension RemoteChord {
    /// A Carbon shortcut as Batuta's `reserve_hotkeys` takes it: the same virtual key code,
    /// and the modifiers by name.
    init(_ combination: KeyCombination) {
        let flags: [(UInt32, Modifier)] = [
            (UInt32(cmdKey), .command), (UInt32(optionKey), .option), (UInt32(controlKey), .control), (UInt32(shiftKey), .shift),
        ]
        self.init(keyCode: Int(combination.keyCode),
                  modifiers: Set(flags.filter { combination.modifiers & $0.0 != 0 }.map(\.1)))
    }
}
