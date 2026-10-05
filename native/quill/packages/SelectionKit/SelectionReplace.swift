import CoreGraphics
import Foundation

/// How a replace ended (ARCHITECTURE §2, PRODUCT §4.1 "Applied").
public enum ReplaceOutcome: String, Codable, Sendable {
    /// Verified: the field holds the result.
    case replaced
    /// Pasted; the field could not be re-read to confirm.
    case pasted
    /// Pasted, but re-reading found no change.
    case pastedUnconfirmed
    /// Pasted with no complete snapshot: the clipboard now holds the rewrite.
    case pastedClipboardHoldsRewrite
    /// The selection changed while the picker was open: the result is on the clipboard.
    case copiedSelectionChanged
    /// Focus did not come back in time: the result is on the clipboard.
    case copiedFocusNotReturned
    /// The target is not confirmed editable: the result is on the clipboard.
    case copiedNotEditable
    /// A clipboard read that timed out is still running: nothing was written; try again
    /// when it ends (the session's waitingForClipboard state, ARCHITECTURE §3.4).
    case clipboardBusy
}

/// The replace sequence of ARCHITECTURE §3.2.
public struct SelectionReplacer: Sendable {
    /// Every cap of §3.2 and §11.
    public static let keyReleaseWait: Duration = .milliseconds(400)
    public static let focusWait: Duration = .milliseconds(600)
    public static let modifierWait: Duration = .milliseconds(400)
    public static let snapshotDeadline: Duration = .milliseconds(300)
    /// The extra wait for a timed-out read before giving up for now.
    public static let pendingReadWait: Duration = .milliseconds(300)

    /// The Return key, waited up before anything else (Ámbar 1.1.1: a paste posted while
    /// Return is down beeps in the host).
    public static let returnKeyCode: CGKeyCode = 36

    let operations: SelectionOperations
    let strategy: @Sendable (String?) -> AppStrategy

    public init(operations: SelectionOperations,
                strategy: @escaping @Sendable (String?) -> AppStrategy = { AppStrategy.strategy(for: $0) }) {
        self.operations = operations
        self.strategy = strategy
    }

    /// The snapshot taken while the model generates (off the critical path). Only with
    /// Always Allow; otherwise there is nothing to restore.
    public func takeSnapshot() async -> PasteboardSnapshotter.Outcome {
        await PasteboardSnapshotter.take(from: operations.pasteboard, deadline: Self.snapshotDeadline, clock: ContinuousClock())
    }

    /// Replaces `capture`'s selection with `result`.
    ///
    /// - Parameters:
    ///   - pasteAnyway: the user chose Paste anyway for an uncertain target (⌥Return).
    ///   - snapshot: the one taken during generation, if any; retaken when the clipboard
    ///     changed since.
    ///   - orderOut: orders the picker out — not alpha-hidden: a hidden panel keeps key
    ///     status and swallows ⌘V.
    public func replace<C: Clock>(
        _ result: String, capture: Capture, pasteAnyway: Bool = false,
        snapshot: PasteboardSnapshotter.Outcome?, orderOut: @Sendable () async -> Void, clock: C
    ) async -> ReplaceOutcome where C.Duration == Duration {
        let keys = operations.keys
        let pasteboard = operations.pasteboard
        let appStrategy = strategy(capture.app.bundleIdentifier)

        // 1. Return key-up.
        _ = await Polling.wait(timeout: Self.keyReleaseWait, clock: clock) { !keys.isKeyDown(Self.returnKeyCode) }
        // 2. Order the picker out.
        await orderOut()

        // Not confirmed editable: copy instead (terminals always; uncertain targets
        // unless the user chose Paste anyway).
        let mayPaste = capture.editability == .editable || (capture.editability == .uncertain && pasteAnyway)
        guard mayPaste else { return await copy(result, snapshot: snapshot, outcome: .copiedNotEditable) }

        // 3. Focus returns: the same element, or — Chromium recreates element objects — the
        // same app, which the selection check then decides.
        let focusBack = await Polling.wait(timeout: Self.focusWait, clock: clock) {
            if let element = capture.element, case .success(let focused) = operations.focusedElement(),
               focused.element == element { return true }
            return operations.focusedApplicationPID() == capture.app.pid
        }
        guard focusBack else { return await copy(result, snapshot: snapshot, outcome: .copiedFocusNotReturned) }

        // 4. The selection is what was captured.
        if let element = capture.element, capture.range != nil || capture.method == .accessibility {
            let now = operations.readSelection(of: element)
            let sameText = now.text.map { $0 == capture.text } ?? (capture.method == .copy)
            let sameRange = capture.range.map { range in
                now.range.map { $0.location == range.location && $0.length == range.length } ?? false
            } ?? true
            if !(sameText && sameRange) {
                return await copy(result, snapshot: snapshot, outcome: .copiedSelectionChanged)
            }
        }

        // Accessibility-write strategy: no clipboard, and no ⌘Z promise.
        if appStrategy.replaceViaAccessibilityWrite, let element = capture.element {
            _ = operations.writeSelectedText(result, to: element)
            return verify(result, element: element) == .verified ? .replaced : .pastedUnconfirmed
        }

        // 5. The snapshot: retaken if the clipboard changed since; never written over while
        // a timed-out read may still be running.
        var saved = snapshot
        if let pending = saved?.pendingRead {
            guard let finished = await Self.finish(pending, within: Self.pendingReadWait) else { return .clipboardBusy }
            saved = PasteboardSnapshotter.Outcome(snapshot: finished, pendingRead: nil)
        }
        if saved == nil || saved?.snapshot.changeCount != pasteboard.changeCount() {
            saved = await takeSnapshot()
            if let pending = saved?.pendingRead {
                guard let finished = await Self.finish(pending, within: Self.pendingReadWait) else { return .clipboardBusy }
                saved = PasteboardSnapshotter.Outcome(snapshot: finished, pendingRead: nil)
            }
        }

        // 6. Write the result: host-only, marked so clipboard managers skip it.
        let text = pasteAnyway ? Self.trimmingTrailingLineBreaks(result) : result
        let written = operations.writeTransient(text)

        // 7. Modifiers clear, then ⌘V in the current layout's ⌘ position.
        _ = await operations.waitForModifiersToClear(timeout: Self.modifierWait, clock: clock)
        _ = await operations.paste()
        let pastedAt = clock.now
        let delay = appStrategy.effectiveRestoreDelay

        // 8. Verify by re-reading — polled through the restore delay: the host applies the
        // paste asynchronously, so a read right after ⌘V still sees the old text (measured
        // in TextEdit, P2-T5).
        var verification = Verification.unverifiable
        if let element = capture.element {
            _ = await Polling.wait(timeout: delay, clock: clock) {
                verification = verify(text, element: element)
                return verification == .verified
            }
        }

        // 9. Restore once the delay since ⌘V has passed — only a complete snapshot, only if
        // the clipboard still holds what Quill wrote.
        let remaining = delay - pastedAt.duration(to: clock.now)
        if remaining > .zero { try? await clock.sleep(for: remaining) }
        let restored = PasteboardSnapshotter.restore(saved?.snapshot, to: pasteboard, ifChangeCountIs: written)
        if restored == .skippedIncomplete { return .pastedClipboardHoldsRewrite }
        switch verification {
        case .verified: return .replaced
        case .unverifiable: return .pasted
        case .unchanged: return .pastedUnconfirmed
        }
    }

    enum Verification { case verified, unverifiable, unchanged }

    /// The value contains the result, or the selection collapsed after it.
    func verify(_ text: String, element: AccessibilityElement) -> Verification {
        guard let value = operations.value(of: element), !value.isEmpty else { return .unverifiable }
        return value.contains(text) ? .verified : .unchanged
    }

    /// ⌘C in the picker: copies `result` unless a timed-out snapshot read is still
    /// running, in which case nothing is written and it returns false — the session then
    /// waits for the read (ARCHITECTURE §3.4).
    public func copyResult(_ result: String, snapshot: PasteboardSnapshotter.Outcome?) async -> Bool {
        await copy(result, snapshot: snapshot, outcome: .copiedNotEditable) != .clipboardBusy
    }

    /// Copy: the result on the clipboard, kept off Universal Clipboard. Never while a
    /// timed-out snapshot read may still be running.
    private func copy(_ result: String, snapshot: PasteboardSnapshotter.Outcome?, outcome: ReplaceOutcome) async -> ReplaceOutcome {
        if let pending = snapshot?.pendingRead, await Self.finish(pending, within: Self.pendingReadWait) == nil {
            return .clipboardBusy
        }
        operations.pasteboard.write([PasteboardItemData(entries: [
            .init(type: "public.utf8-plain-text", data: Data(result.utf8)),
        ])], hostOnly: true)
        return outcome
    }

    /// Waits for a pending read up to `limit` of real time.
    static func finish(_ read: SnapshotRead, within limit: Duration) async -> PasteboardSnapshot? {
        if read.isFinished { return await read.finished() }
        let deadline = ContinuousClock.now.advanced(by: limit)
        while ContinuousClock.now < deadline {
            if read.isFinished { return await read.finished() }
            try? await Task.sleep(for: Polling.interval)
        }
        return read.isFinished ? await read.finished() : nil
    }

    /// Paste anyway removes trailing line breaks: an uncertain target may be a single-line
    /// field that would submit on a pasted newline.
    static func trimmingTrailingLineBreaks(_ text: String) -> String {
        var result = text
        while let last = result.last, last.isNewline { result.removeLast() }
        return result
    }
}
