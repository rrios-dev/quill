import Foundation

/// Per-app overrides of how SelectionKit captures and replaces (ARCHITECTURE §3.3).
///
/// The table is data, and every entry cites the row of `docs/initiatives/quill/SPIKES.md`
/// that justified it; a test checks that each cited row exists. Apps without an entry
/// use `default`.
public struct AppStrategy: Equatable, Sendable {
    /// A signal that a target is editable when its selected text is not settable.
    public enum EditableSignal: String, Codable, Sendable {
        /// `kAXValue` is settable on the focused element.
        case settableValue
        /// The focused element has an `AXEditableAncestor`.
        case editableAncestor
    }

    /// Capture with ⌘C instead of reading the selection through accessibility.
    public var captureViaCopyOnly = false
    /// Replace by writing `kAXSelectedText` instead of pasting. Direct apply is never
    /// used where this is set (PRODUCT F2).
    public var replaceViaAccessibilityWrite = false
    /// How long after ⌘V the pasteboard is restored; nil uses `defaultRestoreDelay`.
    public var restoreDelay: Duration?
    /// Never paste here, not even with Paste anyway: terminals run what they receive.
    public var readOnlyOnly = false
    /// May switch on `AXEnhancedUserInterface` (VoiceOver's switch), off by default.
    public var enhancedAccessibilityAllowed = false
    /// ⌘Z was verified to undo a paste here — direct apply requires it.
    public var undoVerified = false
    public var editableSignal: EditableSignal?
    /// The SPIKES.md rows this entry rests on.
    public var rows: [String] = []

    public init(
        captureViaCopyOnly: Bool = false,
        replaceViaAccessibilityWrite: Bool = false,
        restoreDelay: Duration? = nil,
        readOnlyOnly: Bool = false,
        enhancedAccessibilityAllowed: Bool = false,
        undoVerified: Bool = false,
        editableSignal: EditableSignal? = nil,
        rows: [String] = []
    ) {
        self.captureViaCopyOnly = captureViaCopyOnly
        self.replaceViaAccessibilityWrite = replaceViaAccessibilityWrite
        self.restoreDelay = restoreDelay
        self.readOnlyOnly = readOnlyOnly
        self.enhancedAccessibilityAllowed = enhancedAccessibilityAllowed
        self.undoVerified = undoVerified
        self.editableSignal = editableSignal
        self.rows = rows
    }

    /// No overrides.
    public static let `default` = AppStrategy()

    /// The restore delay when an entry sets none (SPIKES.md, "Default restore delay").
    public static let defaultRestoreDelay: Duration = .milliseconds(300)

    /// The strategy for an app.
    public static func strategy(for bundleIdentifier: String?) -> AppStrategy {
        bundleIdentifier.flatMap { table[$0] } ?? .default
    }

    public var effectiveRestoreDelay: Duration { restoreDelay ?? Self.defaultRestoreDelay }

    /// The terminal denylist is a category rule: Terminal and iTerm2 are its tested
    /// representatives (S1-20, S1-21), and the other terminals cite them.
    static let terminal = AppStrategy(readOnlyOnly: true, rows: ["S1-20", "S1-21"])

    /// The initial table. Each entry cites its rows.
    public static let table: [String: AppStrategy] = [
        "com.apple.TextEdit": AppStrategy(undoVerified: true, rows: ["S2-01", "S2-02"]),
        "com.apple.Notes": AppStrategy(undoVerified: true, rows: ["S2-07", "S2-08"]),
        // Mail's body is WebKit: kAXSelectedText has no value there, so capture goes
        // through ⌘C, and the settable AXValue of its web area is the editable signal.
        "com.apple.mail": AppStrategy(
            captureViaCopyOnly: true, undoVerified: true, editableSignal: .settableValue,
            rows: ["S1-04", "S1-05", "S2-10"]),
        "com.apple.Terminal": terminal,
        "com.googlecode.iterm2": terminal,
        "dev.warp.Warp-Stable": terminal,
        "com.mitchellh.ghostty": terminal,
        "net.kovidgoyal.kitty": terminal,
        "org.alacritty": terminal,
    ]
}
