import AppKit
import AppCore
import Carbon.HIToolbox
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

    typealias Register = @MainActor (KeyCombination, @escaping () -> Void) -> Result<UInt32, HotKeyRegistrationError>
    typealias Unregister = @MainActor (UInt32) -> Void

    private(set) var state: State = .unregistered
    private var identifier: UInt32?
    private let registerExclusive: Register
    private let unregister: Unregister

    init(
        register: @escaping Register = { HotKeyCenter.shared.register($0, options: .exclusive, action: $1) },
        unregister: @escaping Unregister = { HotKeyCenter.shared.unregister($0) }
    ) {
        self.registerExclusive = register
        self.unregister = unregister
    }

    /// Replaces the current registration with `combination`.
    func register(_ combination: KeyCombination, action: @escaping () -> Void) {
        if let identifier { unregister(identifier) }
        identifier = nil
        switch registerExclusive(combination, action) {
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
}

extension KeyCombination {
    init(_ stored: StoredShortcut) { self.init(keyCode: stored.keyCode, modifiers: stored.modifiers) }
}
