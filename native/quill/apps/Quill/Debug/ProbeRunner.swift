#if DEBUG

import AppKit
import Foundation
import QuillSupport
import SelectionKit

/// Debug → Probe frontmost app (ARCHITECTURE §3.6).
///
/// Runs SelectionKit's raw operations against the frontmost app, one by one, and writes
/// what each returned to one JSON row in `<data dir>/probe/`. It runs inside the signed
/// app, so it uses Quill's own Accessibility grant — a command-line probe would borrow
/// the terminal's — and the real code the capture and replace sequences are built from.
///
/// Rows record lengths and booleans, never the selected text itself.
struct ProbeRunner: Sendable {
    enum ReplaceMode: String, Codable, Sendable, CaseIterable {
        case none
        case paste
        case accessibilityWrite
    }

    struct Options: Codable, Sendable {
        var enhancedAccessibility = false
        var replace: ReplaceMode = .none
        var restoreDelayMilliseconds = 300
        /// Skip the accessibility read and capture with ⌘C, as the "capture via ⌘C only"
        /// strategy does (ARCHITECTURE §3.3).
        var forceCopy = false
        /// Run the final sequences (SelectionCapturer, then SelectionReplacer when a replace
        /// is asked) instead of the raw operations one by one — the P2-T5 regression.
        var sequences = false

        static let restoreDelays = [150, 300, 600, 1000]
    }

    struct Row: Codable, Sendable {
        var kind = "probe"
        var date: Date
        /// A label from whoever triggered the run (the spike driver), to find the row.
        var tag: String?
        var options: Options
        var bundleIdentifier: String?
        var appName: String?
        var trusted: Bool
        var pasteboardAccess: PasteboardAccess

        var focusPath: String?
        var focusError: String?
        var manualAccessibility: String?
        var enhancedAccessibility: String?
        var role: String?
        var subrole: String?
        var domClassList: [String]?
        var refused: String?

        var captureMethod: String?
        var selectedTextLength: Int?
        var selectedTextError: String?
        var selectedRange: [Int]?
        var textMarkerSelectionLength: Int?
        var editability: String?
        var selectedTextSettable: Bool?
        var valueSettable: Bool?
        var formatting: FormattingState?
        var bounds: [Double]?
        var boundsSource: String?

        var copyOutcome: String?
        var copySnapshotComplete: Bool?
        var copyRestore: String?

        var replaceResult: String?
        var verification: String?
        var restore: String?

        var timingsMilliseconds: [String: Double] = [:]
    }

    let operations: SelectionOperations
    let primaryScreenHeight: CGFloat
    private let log = QuillLog(category: "probe")

    /// The test string a probe replace writes, recognisable in the target app.
    static func testString(at date: Date) -> String {
        "\(QuillSupport.productName) probe \(date.formatted(date: .omitted, time: .standard))"
    }

    /// The sequence probe: one capture and, optionally, one replace, as the app will run them.
    func runSequences(options: Options, frontmost: NSRunningApplication?, tag: String?) async -> Row {
        let clock = ContinuousClock()
        var row = Row(date: Date(), tag: tag, options: options, bundleIdentifier: frontmost?.bundleIdentifier,
                      appName: frontmost?.localizedName, trusted: operations.accessibility.isProcessTrusted(),
                      pasteboardAccess: operations.pasteboard.accessBehavior())
        guard let frontmost else { row.refused = "noFrontmostApp"; return finish(row) }
        let app = AppIdentity(pid: frontmost.processIdentifier, bundleIdentifier: frontmost.bundleIdentifier)
        let start = clock.now
        let captured = await SelectionCapturer(operations: operations).capture(
            app: app, hotKeyCode: nil, primaryScreenHeight: primaryScreenHeight, clock: clock)
        row.timingsMilliseconds["capture"] = Self.milliseconds(clock.now - start)
        switch captured {
        case .failure(let refusal):
            row.refused = "\(refusal)"
            return finish(row)
        case .success(let capture):
            row.captureMethod = capture.method.rawValue
            row.selectedTextLength = capture.text.count
            row.editability = capture.editability.rawValue
            row.formatting = capture.formatting
            if let bounds = capture.bounds { row.bounds = [bounds.minX, bounds.minY, bounds.width, bounds.height] }
            log.userText("probe sequence capture", capture.text)
            guard options.replace == .paste else { return finish(row) }
            let replacer = SelectionReplacer(operations: operations)
            let snapshot = await replacer.takeSnapshot()
            let replaceStart = clock.now
            let outcome = await replacer.replace(Self.testString(at: row.date), capture: capture, snapshot: snapshot,
                                                 orderOut: {}, clock: clock)
            row.timingsMilliseconds["replace"] = Self.milliseconds(clock.now - replaceStart)
            row.replaceResult = outcome.rawValue
            return finish(row)
        }
    }

    func run(options: Options, frontmost: NSRunningApplication?, tag: String? = nil) async -> Row {
        if options.sequences { return await runSequences(options: options, frontmost: frontmost, tag: tag) }
        let clock = ContinuousClock()
        var row = Row(
            date: Date(),
            tag: tag,
            options: options,
            bundleIdentifier: frontmost?.bundleIdentifier,
            appName: frontmost?.localizedName,
            trusted: operations.accessibility.isProcessTrusted(),
            pasteboardAccess: operations.pasteboard.accessBehavior()
        )
        operations.configureMessagingTimeout()
        let pid = frontmost?.processIdentifier

        if options.enhancedAccessibility, let pid {
            row.enhancedAccessibility = describe(operations.enableEnhancedUserInterface(pid: pid))
        }

        // 1–2. Focused element; for lazy trees, switch manual accessibility on and poll.
        var focused: SelectionOperations.FocusedElement?
        var read: SelectionOperations.SelectionRead?
        let first = await Self.timed("focus", in: &row, clock: clock) { operations.focusedElement() }
        switch first {
        case .success(let element):
            focused = element
            row.focusPath = element.path.rawValue
            read = await Self.timed("read", in: &row, clock: clock) { operations.readSelection(of: element.element) }
        case .failure(let error):
            row.focusError = "\(error)"
        }
        let selectionEmpty = (read?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if (focused == nil || selectionEmpty), read?.isSecureField != true, let pid {
            row.manualAccessibility = describe(operations.enableManualAccessibility(pid: pid))
            if let retried = await Self.timed("manualAccessibilityPoll", in: &row, clock: clock, {
                await operations.pollForSelection(timeout: .milliseconds(200), clock: clock)
            }) {
                focused = retried.0
                read = retried.1
                row.focusPath = retried.0.path.rawValue
            }
        }

        if let read {
            row.role = read.role
            row.subrole = read.subrole
            row.domClassList = read.domClassList
            row.textMarkerSelectionLength = read.textMarkerSelection?.count
            row.selectedTextSettable = read.selectedTextSettable
            row.valueSettable = read.valueSettable
            row.selectedTextError = read.textError.map { "\($0)" }
            if let range = read.range { row.selectedRange = [range.location, range.length] }
        }

        // 3. Refusals: password fields are never read.
        if read?.isSecureField == true {
            row.refused = "secureField"
            return finish(row)
        }

        if options.forceCopy {
            await copyFallback(into: &row, clock: clock)
        } else if let read, let focused, let text = read.text, !text.isEmpty {
            row.captureMethod = "accessibility"
            row.selectedTextLength = text.count
            log.userText("probe selection", text)
            if let range = read.range {
                row.formatting = await Self.timed("formatting", in: &row, clock: clock) {
                    operations.formattingState(of: focused.element, range: range)
                }
                if let bounds = operations.selectionBounds(
                    of: focused.element, range: range, primaryScreenHeight: primaryScreenHeight
                ) {
                    row.bounds = [bounds.minX, bounds.minY, bounds.width, bounds.height]
                    row.boundsSource = "accessibility"
                }
            }
        } else if focused == nil || read?.textError == .attributeUnsupported || read?.textError == .cannotComplete {
            // 8. ⌘C fallback — only when accessibility is unavailable, never when it
            // reported an empty selection.
            await copyFallback(into: &row, clock: clock)
        } else {
            row.refused = "emptySelection"
        }

        if row.bounds == nil {
            let mouse = await MainActor.run { NSEvent.mouseLocation }
            row.bounds = [mouse.x, mouse.y, 0, 0]
            row.boundsSource = "mouse"
        }

        // Optional replace with a recognisable test string.
        if let focused, row.captureMethod != nil {
            await replace(into: &row, element: focused.element, options: options, clock: clock)
        }
        return finish(row)
    }

    private func copyFallback(
        into row: inout Row,
        clock: ContinuousClock
    ) async {
        let snapshot = await PasteboardSnapshotter.take(
            from: operations.pasteboard, deadline: .milliseconds(200), clock: clock)
        row.copySnapshotComplete = snapshot.snapshot.isComplete
        guard snapshot.snapshot.isComplete else {
            row.refused = "copyFallbackSnapshot:\(snapshot.snapshot.incompleteReason?.rawValue ?? "?")"
            return
        }
        let cleared = await operations.waitForModifiersToClear(timeout: .milliseconds(400), clock: clock)
        guard cleared else {
            row.refused = "modifiersHeld"
            return
        }
        let before = operations.pasteboard.changeCount()
        let outcome = await Self.timed("copy", in: &row, clock: clock) {
            await operations.copySelection(phase: .milliseconds(200), clock: clock)
        }
        switch outcome {
        case .copied(let text):
            row.captureMethod = "copy"
            row.selectedTextLength = text.count
            row.copyOutcome = "copied"
            log.userText("probe copy", text)
        default:
            row.copyOutcome = "\(outcome)"
        }
        let after = operations.pasteboard.changeCount()
        row.copyRestore = after == before
            ? "nothingToRestore"
            : PasteboardSnapshotter.restore(snapshot.snapshot, to: operations.pasteboard, ifChangeCountIs: after).rawValue
    }

    private func replace(
        into row: inout Row,
        element: AccessibilityElement,
        options: Options,
        clock: ContinuousClock
    ) async {
        let test = Self.testString(at: row.date)
        switch options.replace {
        case .none:
            return
        case .accessibilityWrite:
            let result = await Self.timed("accessibilityWrite", in: &row, clock: clock) {
                operations.writeSelectedText(test, to: element)
            }
            row.replaceResult = describe(result)
        case .paste:
            let snapshot = await PasteboardSnapshotter.take(
                from: operations.pasteboard, deadline: .milliseconds(300), clock: clock)
            let written = operations.writeTransient(test)
            _ = await operations.waitForModifiersToClear(timeout: .milliseconds(400), clock: clock)
            let posted = await operations.paste()
            row.replaceResult = posted ? "pasted" : "eventNotPosted"
            try? await clock.sleep(for: .milliseconds(options.restoreDelayMilliseconds))
            row.restore = snapshot.pendingRead != nil
                ? "skippedReadStillRunning"
                : PasteboardSnapshotter.restore(snapshot.snapshot, to: operations.pasteboard, ifChangeCountIs: written).rawValue
        }
        let value = operations.value(of: element)
        row.verification = value.map { $0.contains(test) ? "valueContainsResult" : "valueUnchanged" } ?? "unverifiable"
    }

    /// Runs `body` and records how long it took under `name`.
    private static func timed<T>(
        _ name: String, in row: inout Row, clock: ContinuousClock, _ body: () async -> T
    ) async -> T {
        let start = clock.now
        let value = await body()
        row.timingsMilliseconds[name] = milliseconds(clock.now - start)
        return value
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private func describe(_ result: Result<Void, AccessibilityError>) -> String {
        switch result {
        case .success: "ok"
        case .failure(let error): "\(error)"
        }
    }

    private func finish(_ row: Row) -> Row {
        log.info("probe: \(row.bundleIdentifier ?? "?") method=\(row.captureMethod ?? "none") refused=\(row.refused ?? "-")")
        return row
    }

    /// Writes `row` to `<data dir>/probe/<timestamp>-<bundle id>.json`.
    static func save(_ row: Row, in dataDirectory: URL) throws -> URL {
        try save(row, named: row.bundleIdentifier ?? "unknown", date: row.date, in: dataDirectory)
    }

    /// Writes any probe-folder row as `<timestamp>-<name>.json`.
    static func save<T: Encodable>(_ row: T, named name: String, date: Date, in dataDirectory: URL) throws -> URL {
        let folder = dataDirectory.appendingPathComponent("probe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("\(stamp)-\(name).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(row).write(to: url, options: .atomic)
        return url
    }
}

#endif
