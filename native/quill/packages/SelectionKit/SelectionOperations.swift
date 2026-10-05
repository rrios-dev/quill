import CoreGraphics
import Foundation

/// The raw operations capture and replace are built from (ARCHITECTURE §3.1–3.4).
///
/// Each does one thing and reports what happened, without policy: the probe and the
/// spikes call them one by one to learn which strategy works in which app, and the
/// capture and replace sequences (PLAN P2) compose them. Accessibility calls block for
/// up to the messaging timeout, so none of these runs on the main thread.
public struct SelectionOperations: Sendable {
    public let accessibility: any AccessibilityClient
    public let pasteboard: any PasteboardClient
    public let keys: any KeyEventPoster

    public init(
        accessibility: any AccessibilityClient,
        pasteboard: any PasteboardClient,
        keys: any KeyEventPoster
    ) {
        self.accessibility = accessibility
        self.pasteboard = pasteboard
        self.keys = keys
    }

    /// The messaging timeout set on the system-wide element (process-wide), so a busy
    /// host cannot stall Quill for the system default of several seconds.
    public static let messagingTimeout: Float = 0.1

    public func configureMessagingTimeout() {
        accessibility.setMessagingTimeout(Self.messagingTimeout, on: accessibility.systemWide())
    }

    // MARK: Focused element

    public enum FocusPath: String, Codable, Sendable {
        case systemWide
        case frontmostApplication
    }

    public struct FocusedElement: Sendable {
        public var element: AccessibilityElement
        public var pid: pid_t?
        public var path: FocusPath
    }

    /// System-wide focus first; when that fails or returns nothing, the frontmost
    /// application's focused element.
    public func focusedElement() -> Result<FocusedElement, AccessibilityError> {
        let systemWide = accessibility.element("AXFocusedUIElement", of: accessibility.systemWide())
        if case .success(let element) = systemWide {
            return .success(FocusedElement(element: element, pid: accessibility.pid(of: element), path: .systemWide))
        }
        guard let pid = accessibility.frontmostApplicationPID() else {
            return systemWide.map { FocusedElement(element: $0, pid: nil, path: .systemWide) }
        }
        return accessibility.element("AXFocusedUIElement", of: accessibility.application(pid: pid))
            .map { FocusedElement(element: $0, pid: pid, path: .frontmostApplication) }
    }

    /// The pid of the application that holds keyboard focus (`AXFocusedApplication`) —
    /// the coarse focus-return signal `AppCore.Paster.waitForKeyboardFocus` checks.
    ///
    /// When the system-wide element cannot answer at all — measured on 2026-10-05 with
    /// InputLeap running: every system-wide query fails with `kAXErrorCannotComplete` —
    /// the frontmost application stands in for it: the same app-level signal, from
    /// NSWorkspace instead of accessibility. It cannot also require a focused element:
    /// Microsoft Teams exposes none at all (its AXFocusedUIElement and AXFocusedWindow
    /// answer `kAXErrorNoValue`), which is why its selection is read with ⌘C. Without
    /// this, every replace there only copied the result.
    public func focusedApplicationPID() -> pid_t? {
        switch accessibility.element("AXFocusedApplication", of: accessibility.systemWide()) {
        case .success(let application):
            return accessibility.pid(of: application)
        case .failure:
            return accessibility.frontmostApplicationPID()
        }
    }

    // MARK: Lazy trees

    /// Asks a Chromium/Electron app to build its accessibility tree
    /// (`AXManualAccessibility`). Apps that do not know the attribute answer
    /// `attributeUnsupported`, which is harmless.
    public func enableManualAccessibility(pid: pid_t) -> Result<Void, AccessibilityError> {
        accessibility.setBool(true, for: "AXManualAccessibility", of: accessibility.application(pid: pid))
    }

    /// VoiceOver's switch. Off by default — it breaks window-manager animations — and
    /// only for apps whose strategy entry allows it (ARCHITECTURE §3.1 step 2).
    public func enableEnhancedUserInterface(pid: pid_t) -> Result<Void, AccessibilityError> {
        accessibility.setBool(true, for: "AXEnhancedUserInterface", of: accessibility.application(pid: pid))
    }

    /// Polls until the focused element reports a non-empty selection or `timeout`
    /// passes: Chromium builds its tree asynchronously, and a tree still being built may
    /// answer with an empty selection rather than an error.
    public func pollForSelection<C: Clock>(
        timeout: Duration, clock: C
    ) async -> (FocusedElement, SelectionRead)? where C.Duration == Duration {
        var found: (FocusedElement, SelectionRead)?
        _ = await Polling.wait(timeout: timeout, clock: clock) {
            guard case .success(let focused) = focusedElement() else { return false }
            let read = readSelection(of: focused.element)
            guard let text = read.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            found = (focused, read)
            return true
        }
        return found
    }

    // MARK: Reading

    /// What the focused element says about itself and its selection.
    public struct SelectionRead: Sendable {
        public var role: String?
        public var subrole: String?
        public var text: String?
        public var textError: AccessibilityError?
        public var range: CFRange?
        /// `kAXSelectedText` settable — the default editability signal.
        public var selectedTextSettable: Bool?
        /// `kAXValue` settable — an editable signal some apps need instead (§3.3).
        public var valueSettable: Bool?
        public var domClassList: [String]?
        /// The selection read through WebKit's text markers, when the element has them
        /// (measured for spike S1; capture does not use it yet).
        public var textMarkerSelection: String?

        public init(role: String? = nil, subrole: String? = nil, text: String? = nil, textError: AccessibilityError? = nil,
                    range: CFRange? = nil, selectedTextSettable: Bool? = nil, valueSettable: Bool? = nil,
                    domClassList: [String]? = nil, textMarkerSelection: String? = nil) {
            self.role = role
            self.subrole = subrole
            self.text = text
            self.textError = textError
            self.range = range
            self.selectedTextSettable = selectedTextSettable
            self.valueSettable = valueSettable
            self.domClassList = domClassList
            self.textMarkerSelection = textMarkerSelection
        }

        /// A password field's **subrole** is the secure one; its role is a plain
        /// `AXTextField`, so checking the role would never match.
        public var isSecureField: Bool { subrole == "AXSecureTextField" }

        /// VS Code's integrated terminal (xterm.js) — read-only-only (§3.1 step 5).
        public var isTerminalHelper: Bool { domClassList?.contains("xterm-helper-textarea") ?? false }
    }

    public func readSelection(of element: AccessibilityElement) -> SelectionRead {
        let text = accessibility.string("AXSelectedText", of: element)
        return SelectionRead(
            role: try? accessibility.string("AXRole", of: element).get(),
            subrole: try? accessibility.string("AXSubrole", of: element).get(),
            text: try? text.get(),
            textError: text.failure,
            range: try? accessibility.range("AXSelectedTextRange", of: element).get(),
            selectedTextSettable: try? accessibility.isSettable("AXSelectedText", of: element).get(),
            valueSettable: try? accessibility.isSettable("AXValue", of: element).get(),
            domClassList: try? accessibility.strings("AXDOMClassList", of: element).get(),
            textMarkerSelection: try? accessibility.selectedTextViaTextMarkers(of: element).get()
        )
    }

    /// The value, for verifying a replace by re-reading it.
    public func value(of element: AccessibilityElement) -> String? {
        try? accessibility.string("AXValue", of: element).get()
    }

    public func formattingState(of element: AccessibilityElement, range: CFRange) -> FormattingState {
        switch accessibility.attributeRuns(in: range, of: element) {
        case .success(let runs): FormattingDetector.state(of: runs)
        case .failure: .unknown
        }
    }

    /// The selection's bounds in Cocoa screen coordinates.
    public func selectionBounds(
        of element: AccessibilityElement, range: CFRange, primaryScreenHeight: CGFloat
    ) -> CGRect? {
        guard let rect = try? accessibility.bounds(for: range, of: element).get(), !rect.isNull else { return nil }
        return ScreenGeometry.cocoaRect(fromAccessibility: rect, primaryScreenHeight: primaryScreenHeight)
    }

    // MARK: Writing

    /// Writes `text` through accessibility (`kAXSelectedText`). Can report success
    /// without changing the field, and bypasses the host's undo — a per-app fallback,
    /// never the primary path (README D-08).
    public func writeSelectedText(_ text: String, to element: AccessibilityElement) -> Result<Void, AccessibilityError> {
        accessibility.setString(text, for: "AXSelectedText", of: element)
    }

    /// Puts `text` on the pasteboard host-only, with the transient and concealed
    /// markers. Returns the change count to guard the restore with.
    @discardableResult
    public func writeTransient(_ text: String) -> Int {
        pasteboard.write([PasteboardMarkers.transientText(text)], hostOnly: true)
    }

    public func paste() async -> Bool { await keys.postCommandShortcut("v") }

    // MARK: ⌘C

    public enum CopyOutcome: Sendable, Equatable {
        case copied(String)
        /// Only Always Allow lets Quill read what the host copied.
        case readingNotAllowed
        case eventNotPosted
        /// `changeCount` did not move within the phase: nothing selected, the host
        /// ignored ⌘C, or secure input swallowed the event.
        case noChange
        case noString
    }

    /// Posts ⌘C and reads what the host put on the pasteboard, within `phase`.
    ///
    /// Does not snapshot or restore: callers that must keep the user's clipboard take
    /// the snapshot first (§3.1 step 8). The host writes that copy without privacy
    /// markers, which PRODUCT §7 discloses.
    public func copySelection<C: Clock>(phase: Duration, clock: C) async -> CopyOutcome where C.Duration == Duration {
        guard pasteboard.accessBehavior().allowsReading else { return .readingNotAllowed }
        let before = pasteboard.changeCount()
        guard await keys.postCommandShortcut("c") else { return .eventNotPosted }
        // The change count moves when the host clears the pasteboard, which can come
        // before it writes the text (measured in Mail: one capture in three read
        // nothing). So the poll waits for the string itself, within the same phase.
        var moved = false
        var copied: String?
        _ = await Polling.wait(timeout: phase, clock: clock) {
            guard pasteboard.changeCount() != before else { return false }
            moved = true
            copied = pasteboard.string()
            return copied != nil
        }
        guard moved else { return .noChange }
        guard let copied else { return .noString }
        return .copied(copied)
    }

    /// Waits until ⇧, ⌃ and ⌥ are up (or `timeout`). Returns whether they cleared.
    ///
    /// ⌘ is not waited for, as in `AppCore.Paster.waitForModifiersToClear`: the posted
    /// event is ⌘C or ⌘V, so a ⌘ still held combines into exactly what is posted.
    public func waitForModifiersToClear<C: Clock>(timeout: Duration, clock: C) async -> Bool where C.Duration == Duration {
        await Polling.wait(timeout: timeout, clock: clock) {
            keys.heldModifiers().intersection([.shift, .control, .option]).isEmpty
        }
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
