import CoreGraphics
import Foundation

/// The app a capture targets.
public struct AppIdentity: Hashable, Sendable {
    public var pid: pid_t
    public var bundleIdentifier: String?

    public init(pid: pid_t, bundleIdentifier: String?) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Whether Quill may replace the selection (ARCHITECTURE §3.1 step 5, PRODUCT §4.1).
public enum Editability: String, Codable, Sendable {
    /// The selected text is settable, or the app's editable signal holds.
    case editable
    /// Could not be confirmed: the picker offers Copy and "Paste anyway".
    case uncertain
    /// Terminals: never pasted into, not even with Paste anyway.
    case readOnlyOnly
}

public enum CaptureMethod: String, Codable, Sendable {
    case accessibility
    case copy
}

/// A captured selection.
public struct Capture: Sendable {
    public var text: String
    public var app: AppIdentity
    public var element: AccessibilityElement?
    public var range: CFRange?
    public var editability: Editability
    public var formatting: FormattingState
    /// In Cocoa screen coordinates; nil means "place the picker at the mouse".
    public var bounds: CGRect?
    public var method: CaptureMethod
    public var elapsed: Duration

    /// Public so the app can build one for the Services entry (the text arrives through
    /// the service, the element through accessibility) and its tests can build fakes.
    public init(text: String, app: AppIdentity, element: AccessibilityElement? = nil, range: CFRange? = nil,
                editability: Editability, formatting: FormattingState = .unknown, bounds: CGRect? = nil,
                method: CaptureMethod, elapsed: Duration = .zero) {
        self.text = text
        self.app = app
        self.element = element
        self.range = range
        self.editability = editability
        self.formatting = formatting
        self.bounds = bounds
        self.method = method
        self.elapsed = elapsed
    }
}

/// Why nothing was captured — each with its own copy in the picker (PRODUCT §4.1).
public enum CaptureRefusal: Error, Equatable, Sendable {
    case notTrusted
    /// "Quill never reads password fields."
    case passwordField
    /// "Select some text first" — and no ⌘C, which in VS Code copies the whole line.
    case noSelection
    /// The app exposes no text and the ⌘C fallback needs Always Allow clipboard access.
    case copyNeedsAlwaysAllow
    /// The ⌘C fallback is turned off in Settings.
    case copyDisabled
    /// The clipboard could not be saved in time, so ⌘C would risk the user's copy.
    case clipboardNotSaved
    /// Modifier keys still held after the cap: ⌘C would reach the host combined with them.
    case modifiersHeld
    /// ⌘C produced nothing (nothing selected, the host ignored it, or secure input).
    case nothingCopied
}

/// The settings capture reads (kill switches, ARCHITECTURE §3.1 step 2 and step 8).
public struct CaptureSettings: Sendable {
    public var copyFallbackEnabled = true
    public var manualAccessibilityEnabled = true
    public var enhancedAccessibilityEnabled = true

    public init(copyFallbackEnabled: Bool = true, manualAccessibilityEnabled: Bool = true,
                enhancedAccessibilityEnabled: Bool = true) {
        self.copyFallbackEnabled = copyFallbackEnabled
        self.manualAccessibilityEnabled = manualAccessibilityEnabled
        self.enhancedAccessibilityEnabled = enhancedAccessibilityEnabled
    }
}

/// The capture sequence of ARCHITECTURE §3.1, with the strategy table of SPIKES.md.
public final class SelectionCapturer: @unchecked Sendable {
    /// The accessibility phase; when it captures, it is the whole capture.
    public static let accessibilityPhase: Duration = .milliseconds(200)
    /// The wait for the hot key's release and the modifiers, within the ⌘C path.
    public static let modifierWait: Duration = .milliseconds(400)
    /// ⌘C's own phase, after the modifiers clear.
    public static let copyPhase: Duration = .milliseconds(200)
    /// The ⌘C path's snapshot deadline, running in parallel with the modifier wait.
    public static let copySnapshotDeadline: Duration = .milliseconds(200)

    let operations: SelectionOperations
    let settings: CaptureSettings
    let strategy: @Sendable (String?) -> AppStrategy

    private let lock = NSLock()
    /// Processes already asked to build their tree, remembered for their lifetime.
    private var switchedProcesses: Set<pid_t> = []
    private var enhancedProcesses: Set<pid_t> = []
    private var timeoutConfigured = false

    public init(operations: SelectionOperations, settings: CaptureSettings = CaptureSettings(),
                strategy: @escaping @Sendable (String?) -> AppStrategy = { AppStrategy.strategy(for: $0) }) {
        self.operations = operations
        self.settings = settings
        self.strategy = strategy
    }

    /// Forgets a process that quit (a new process with the same pid starts unswitched).
    public func processTerminated(_ pid: pid_t) {
        lock.withLock {
            switchedProcesses.remove(pid)
            enhancedProcesses.remove(pid)
        }
    }

    /// Captures the selection of `app`. `hotKeyCode` is the trigger's key, waited up before
    /// any ⌘C; `clock` drives every wait (a manual clock in tests).
    public func capture<C: Clock>(
        app: AppIdentity, hotKeyCode: CGKeyCode?, primaryScreenHeight: CGFloat, clock: C
    ) async -> Result<Capture, CaptureRefusal> where C.Duration == Duration {
        let start = clock.now
        guard operations.accessibility.isProcessTrusted() else { return .failure(.notTrusted) }
        let firstTime = lock.withLock { () -> Bool in
            defer { timeoutConfigured = true }
            return !timeoutConfigured
        }
        if firstTime { operations.configureMessagingTimeout() }

        let appStrategy = strategy(app.bundleIdentifier)
        if appStrategy.enhancedAccessibilityAllowed, settings.enhancedAccessibilityEnabled,
           lock.withLock({ enhancedProcesses.insert(app.pid).inserted }) {
            _ = operations.enableEnhancedUserInterface(pid: app.pid)
        }

        // 1–2. The focused element, with the lazy-tree retry.
        var focused = try? operations.focusedElement().get()
        var read = focused.map { operations.readSelection(of: $0.element) }
        if read?.isSecureField == true { return .failure(.passwordField) }

        if !appStrategy.captureViaCopyOnly {
            let empty = read?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            if focused == nil || empty, settings.manualAccessibilityEnabled,
               lock.withLock({ switchedProcesses.insert(app.pid).inserted }) {
                _ = operations.enableManualAccessibility(pid: app.pid)
                let remaining = Self.accessibilityPhase - start.duration(to: clock.now)
                if remaining > .zero, let found = await operations.pollForSelection(timeout: remaining, clock: clock) {
                    focused = found.0
                    read = found.1
                } else if let retry = try? operations.focusedElement().get() {
                    focused = retry
                    read = operations.readSelection(of: retry.element)
                }
            }
            // 3. Refusals.
            if read?.isSecureField == true { return .failure(.passwordField) }
            if let focused, let read, let text = read.text,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .success(accessibilityCapture(text: text, focused: focused, read: read, app: app,
                                                     strategy: appStrategy, primaryScreenHeight: primaryScreenHeight,
                                                     elapsed: start.duration(to: clock.now)))
            }
            // An empty answer is believed after the retry: no ⌘C fallback.
            if focused != nil, Self.answeredEmpty(read) { return .failure(.noSelection) }
        }

        // 8. The ⌘C fallback: accessibility unavailable, or the app's strategy says so.
        return await copyCapture(app: app, focused: focused, read: read, strategy: appStrategy,
                                 hotKeyCode: hotKeyCode, primaryScreenHeight: primaryScreenHeight,
                                 clock: clock, start: start)
    }

    /// The element answered, with an empty selection (not an error or an unsupported
    /// attribute, which mean accessibility is unavailable).
    static func answeredEmpty(_ read: SelectionOperations.SelectionRead?) -> Bool {
        guard let read else { return false }
        if let text = read.text { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return read.textError == .noValue
    }

    func editability(_ read: SelectionOperations.SelectionRead?, element: AccessibilityElement?,
                     strategy: AppStrategy) -> Editability {
        if strategy.readOnlyOnly || read?.isTerminalHelper == true { return .readOnlyOnly }
        if read?.selectedTextSettable == true { return .editable }
        switch strategy.editableSignal {
        case .settableValue? where read?.valueSettable == true:
            return .editable
        case .editableAncestor?:
            if let element, (try? operations.accessibility.element("AXEditableAncestor", of: element).get()) != nil {
                return .editable
            }
        default:
            break
        }
        return .uncertain
    }

    private func accessibilityCapture(
        text: String, focused: SelectionOperations.FocusedElement, read: SelectionOperations.SelectionRead,
        app: AppIdentity, strategy: AppStrategy, primaryScreenHeight: CGFloat, elapsed: Duration
    ) -> Capture {
        let formatting = read.range.map { operations.formattingState(of: focused.element, range: $0) } ?? .unknown
        let bounds = read.range.flatMap {
            operations.selectionBounds(of: focused.element, range: $0, primaryScreenHeight: primaryScreenHeight)
        }
        return Capture(text: text, app: app, element: focused.element, range: read.range,
                       editability: editability(read, element: focused.element, strategy: strategy),
                       formatting: formatting, bounds: bounds, method: .accessibility, elapsed: elapsed)
    }

    private func copyCapture<C: Clock>(
        app: AppIdentity, focused: SelectionOperations.FocusedElement?, read: SelectionOperations.SelectionRead?,
        strategy: AppStrategy, hotKeyCode: CGKeyCode?, primaryScreenHeight: CGFloat, clock: C, start: C.Instant
    ) async -> Result<Capture, CaptureRefusal> where C.Duration == Duration {
        guard settings.copyFallbackEnabled else { return .failure(.copyDisabled) }
        let pasteboard = operations.pasteboard
        guard pasteboard.accessBehavior().allowsReading else { return .failure(.copyNeedsAlwaysAllow) }

        // The snapshot runs in parallel with the wait for the trigger's release and the
        // modifiers. Its deadline is real time: it bounds reads that block in real time.
        async let snapshot = PasteboardSnapshotter.take(
            from: pasteboard, deadline: Self.copySnapshotDeadline, clock: ContinuousClock())
        let keys = operations.keys
        let cleared = await Polling.wait(timeout: Self.modifierWait, clock: clock) {
            !(hotKeyCode.map { keys.isKeyDown($0) } ?? false)
                && keys.heldModifiers().intersection([.shift, .control, .option]).isEmpty
        }
        let saved = await snapshot
        guard saved.snapshot.isComplete else { return .failure(.clipboardNotSaved) }
        guard cleared else { return .failure(.modifiersHeld) }

        let outcome = await operations.copySelection(phase: Self.copyPhase, clock: clock)
        guard case .copied(let text) = outcome else {
            if pasteboard.changeCount() != saved.snapshot.changeCount {
                PasteboardSnapshotter.restore(saved.snapshot, to: pasteboard, ifChangeCountIs: pasteboard.changeCount())
            }
            return .failure(.nothingCopied)
        }
        let formatting = Self.pasteboardFormatting(pasteboard)
        PasteboardSnapshotter.restore(saved.snapshot, to: pasteboard, ifChangeCountIs: pasteboard.changeCount())

        let editability = editability(read, element: focused?.element, strategy: strategy)
        let bounds = read?.range.flatMap { range in
            focused.flatMap { operations.selectionBounds(of: $0.element, range: range, primaryScreenHeight: primaryScreenHeight) }
        }
        return .success(Capture(text: text, app: app, element: focused?.element, range: read?.range,
                                editability: editability,
                                formatting: formatting, bounds: bounds, method: .copy, elapsed: start.duration(to: clock.now)))
    }

    /// Formatting from what the host copied: RTF or HTML runs; plain when it copied text only.
    static func pasteboardFormatting(_ pasteboard: any PasteboardClient) -> FormattingState {
        let types = pasteboard.itemTypes().first ?? []
        if types.contains("public.rtf"), let rtf = pasteboard.data(forType: "public.rtf", item: 0) {
            return FormattingDetector.state(rtf: rtf)
        }
        if types.contains("public.html"), let data = pasteboard.data(forType: "public.html", item: 0),
           let html = String(data: data, encoding: .utf8) {
            return FormattingDetector.state(html: html)
        }
        return .plain
    }
}
