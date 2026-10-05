import CoreGraphics
import Foundation
import Testing

@testable import SelectionKit

/// The replace sequence on fakes (PLAN P2-T3, ARCHITECTURE §3.2), asserting the order.
@Suite("Replace sequence")
struct ReplaceTests {
    struct Rig {
        let log = EffectLog()
        let clock: ManualClock
        let accessibility: FakeAccessibility
        let pasteboard: FakePasteboard
        let keys: FakeKeys
        let replacer: SelectionReplacer

        init(strategy: AppStrategy = .default, items: [PasteboardItemData] = [textItem("the user's own copy")],
             access: PasteboardAccess = .alwaysAllow) {
            clock = ManualClock(log: log)
            accessibility = FakeAccessibility(log: log)
            pasteboard = FakePasteboard(items: items, access: access, log: log)
            keys = FakeKeys(log: log)
            replacer = SelectionReplacer(
                operations: SelectionOperations(accessibility: accessibility, pasteboard: pasteboard, keys: keys),
                strategy: { _ in strategy })
            var node = FakeAccessibility.Node(pid: 7)
            node.values["AXValue"] = .string("hello world")
            node.values["AXSelectedText"] = .string("hello")
            node.values["AXSelectedTextRange"] = .range(CFRange(location: 0, length: 5))
            node.settable = ["AXSelectedText"]
            accessibility.nodes["field"] = node
            accessibility.systemFocus = .success("field")
            // The host pastes what is on the pasteboard when ⌘V arrives.
            let accessibility = accessibility
            let pasteboard = pasteboard
            keys.onPost = { letter in
                guard letter == "v", let text = pasteboard.string() else { return }
                accessibility.nodes["field"]?.values["AXValue"] = .string(text + " world")
            }
        }

        func capture(editability: Editability = .editable, method: CaptureMethod = .accessibility) -> Capture {
            Capture(text: "hello", app: AppIdentity(pid: 7, bundleIdentifier: "com.example.editor"),
                    element: AccessibilityElement(fake: "field"), range: CFRange(location: 0, length: 5),
                    editability: editability, formatting: .plain, bounds: nil, method: method, elapsed: .zero)
        }

        func replace(_ result: String = "Hello", capture: Capture? = nil, pasteAnyway: Bool = false,
                     snapshot: PasteboardSnapshotter.Outcome? = nil) async -> ReplaceOutcome {
            let log = log
            let clock = clock
            return await replacer.replace(result, capture: capture ?? self.capture(), pasteAnyway: pasteAnyway,
                                          snapshot: snapshot, orderOut: { log.append("orderOut at \(clock.elapsed)") }, clock: clock)
        }
    }

    @Test("the order: Return up → order out → focus → selection check → snapshot → write → ⌘V → verify → restore")
    func order() async {
        let rig = Rig()
        let clock = rig.clock
        rig.keys.keysDown = { code in code == SelectionReplacer.returnKeyCode && clock.elapsed < .milliseconds(80) }
        let outcome = await rig.replace()
        #expect(outcome == .replaced)
        let log = rig.log.all
        let orderOut = log.first { $0.hasPrefix("orderOut at ") } ?? ""
        #expect(orderOut.contains("0.08") || orderOut.contains("0.084"), "ordered out after Return came up: \(orderOut)")
        #expect(rig.log.happened("orderOut", before: "read:AXSelectedText"))
        #expect(rig.log.happened("read:AXSelectedText", before: "pasteboardRead"))
        #expect(rig.log.happened("pasteboardRead", before: "write"))
        #expect(rig.log.happened("write", before: "cmdV"))
        #expect(rig.log.happened("cmdV", before: "read:AXValue"))
        #expect(rig.log.happened("read:AXValue", before: "restore"))
        #expect(rig.pasteboard.string() == "the user's own copy")
    }

    @Test("the write is host-only and carries the transient and concealed markers")
    func markers() async {
        let rig = Rig()
        _ = await rig.replace()
        let write = rig.pasteboard.writes.first { $0.items.first?.data(forType: PasteboardMarkers.concealed) != nil }
        #expect(write?.hostOnly == true)
        #expect(write?.items.first?.data(forType: PasteboardMarkers.transient) != nil)
        #expect(rig.pasteboard.writes.last?.hostOnly == true, "the restore is host-only too")
    }

    @Test("⌘V waits for the modifiers")
    func modifiersBeforePaste() async {
        let rig = Rig()
        let clock = rig.clock
        let log = rig.log
        rig.keys.modifiers = { clock.elapsed < .milliseconds(120) ? [.option] : [] }
        let pasteboard = rig.pasteboard
        let accessibility = rig.accessibility
        rig.keys.onPost = { letter in
            log.append("posted at \(clock.elapsed)")
            if letter == "v", let text = pasteboard.string() { accessibility.nodes["field"]?.values["AXValue"] = .string(text + " world") }
        }
        _ = await rig.replace()
        let posted = rig.log.all.first { $0.hasPrefix("posted at ") } ?? ""
        let seconds = Double(posted.split(separator: " ")[2]) ?? 0
        #expect(seconds >= 0.12, "⌘V after the modifiers cleared (\(posted))")
    }

    @Test("focus on another element of the same app proceeds to the selection check (the pid fallback)")
    func pidFallback() async {
        let rig = Rig()
        rig.accessibility.nodes["other"] = FakeAccessibility.Node(pid: 7)
        rig.accessibility.systemFocus = .success("other")
        #expect(await rig.replace() == .replaced)
    }

    @Test("with system-wide accessibility down, the frontmost app's own focus counts as focus back")
    func systemWideDownFallsBackToFrontmost() async {
        // InputLeap running: every system-wide query fails, and a Chromium host has
        // recreated the focused element, so only the frontmost app can tell.
        let rig = Rig()
        rig.accessibility.nodes["recreated"] = FakeAccessibility.Node(pid: 7)
        rig.accessibility.systemFocus = .failure(.cannotComplete)
        rig.accessibility.frontmost = 7
        rig.accessibility.applicationFocus[7] = .success("recreated")
        #expect(await rig.replace() == .replaced)
    }

    @Test("with system-wide accessibility down, another frontmost app is not focus back")
    func systemWideDownOtherAppAborts() async {
        let rig = Rig()
        rig.accessibility.nodes["elsewhere"] = FakeAccessibility.Node(pid: 99)
        rig.accessibility.systemFocus = .failure(.cannotComplete)
        rig.accessibility.frontmost = 99
        rig.accessibility.applicationFocus[99] = .success("elsewhere")
        #expect(await rig.replace() == .copiedFocusNotReturned)
        #expect(rig.keys.postedShortcuts.isEmpty)
    }

    @Test("with system-wide accessibility down, a frontmost app that exposes no accessibility still counts (Teams)")
    func systemWideDownNoTreeProceeds() async {
        // Teams: no focused element at all, the selection captured with ⌘C.
        let rig = Rig()
        rig.accessibility.systemFocus = .failure(.cannotComplete)
        rig.accessibility.frontmost = 7
        let capture = Capture(text: "hello", app: AppIdentity(pid: 7, bundleIdentifier: "com.microsoft.teams2"),
                              element: nil, range: nil, editability: .editable, formatting: .unknown,
                              bounds: nil, method: .copy, elapsed: .zero)
        let outcome = await rig.replace(capture: capture)
        #expect(outcome != .copiedFocusNotReturned)
        #expect(rig.keys.postedShortcuts.contains("v"))
    }

    @Test("focus that never comes back aborts to a copy")
    func focusNeverReturns() async {
        let rig = Rig()
        rig.accessibility.nodes["elsewhere"] = FakeAccessibility.Node(pid: 99)
        rig.accessibility.systemFocus = .success("elsewhere")
        #expect(await rig.replace() == .copiedFocusNotReturned)
        #expect(rig.keys.postedShortcuts.isEmpty)
        #expect(rig.pasteboard.string() == "Hello")
        #expect(rig.clock.elapsed >= SelectionReplacer.focusWait)
    }

    @Test("a changed selection aborts: no paste, the result on the clipboard")
    func selectionChanged() async {
        let rig = Rig()
        rig.accessibility.nodes["field"]?.values["AXSelectedText"] = .string("world")
        rig.accessibility.nodes["field"]?.values["AXSelectedTextRange"] = .range(CFRange(location: 6, length: 5))
        #expect(await rig.replace() == .copiedSelectionChanged)
        #expect(rig.keys.postedShortcuts.isEmpty)
        #expect(rig.pasteboard.string() == "Hello")
    }

    @Test("uncertain targets are copied unless pasted anyway, which drops trailing line breaks; read-only-only is always copied")
    func editability() async {
        let uncertain = Rig()
        #expect(await uncertain.replace(capture: uncertain.capture(editability: .uncertain)) == .copiedNotEditable)

        let anyway = Rig()
        _ = await anyway.replace("Hello\n\n", capture: anyway.capture(editability: .uncertain), pasteAnyway: true)
        let written = anyway.pasteboard.writes.first { $0.items.first?.data(forType: PasteboardMarkers.concealed) != nil }
        #expect(written?.items.first?.data(forType: "public.utf8-plain-text") == Data("Hello".utf8))

        let terminal = Rig()
        #expect(await terminal.replace(capture: terminal.capture(editability: .readOnlyOnly), pasteAnyway: true) == .copiedNotEditable)
        #expect(terminal.keys.postedShortcuts.isEmpty)
    }

    @Test("the restore waits for the delay, needs a snapshot and an unchanged changeCount")
    func restoreRules() async {
        let rig = Rig(strategy: AppStrategy(restoreDelay: .milliseconds(600), rows: ["test"]))
        let clock = rig.clock
        let log = rig.log
        let pasteboard = rig.pasteboard
        let accessibility = rig.accessibility
        rig.keys.onPost = { letter in
            log.append("cmdV at \(clock.elapsed)")
            if letter == "v", let text = pasteboard.string() { accessibility.nodes["field"]?.values["AXValue"] = .string(text + " world") }
        }
        _ = await rig.replace()
        let pasted = Double(rig.log.all.first { $0.hasPrefix("cmdV at ") }?.split(separator: " ")[2] ?? "0") ?? 0
        #expect(rig.clock.elapsed.components.seconds >= 0 && Double(rig.clock.elapsed.components.attoseconds) / 1e18 + Double(rig.clock.elapsed.components.seconds) >= pasted + 0.6)

        // The user copies during the delay: their copy wins.
        let busy = Rig()
        let busyBoard = busy.pasteboard
        let busyAccessibility = busy.accessibility
        busy.keys.onPost = { letter in
            if letter == "v", let text = busyBoard.string() { busyAccessibility.nodes["field"]?.values["AXValue"] = .string(text + " world") }
            busyBoard.simulateUserCopy("copied during the delay")
        }
        #expect(await busy.replace() == .replaced)
        #expect(busy.pasteboard.string() == "copied during the delay")

        // Without Always Allow there is no snapshot: the clipboard keeps the rewrite.
        let denied = Rig(access: .alwaysDeny)
        #expect(await denied.replace() == .pastedClipboardHoldsRewrite)
        #expect(denied.pasteboard.string() == "Hello")
    }

    @Test("a snapshot from generation is reused, and retaken when the clipboard changed since")
    func snapshotReuse() async {
        let rig = Rig()
        let early = await rig.replacer.takeSnapshot()
        let readsBefore = rig.pasteboard.reads
        _ = await rig.replace(snapshot: early)
        #expect(rig.pasteboard.reads - readsBefore <= 2, "no second snapshot")

        let changed = Rig()
        let stale = await changed.replacer.takeSnapshot()
        changed.pasteboard.simulateUserCopy("newer copy")
        _ = await changed.replace(snapshot: stale)
        #expect(changed.pasteboard.string() == "newer copy", "the retaken snapshot restores the newer copy")
    }

    @Test("a host that applies the paste a little later is still verified, and the restore still waits for the delay")
    func asynchronousHost() async {
        let rig = Rig()
        let clock = rig.clock
        let accessibility = rig.accessibility
        let pasteboard = rig.pasteboard
        let pending = PendingPaste()
        rig.keys.onPost = { letter in if letter == "v" { pending.set(pasteboard.string(), at: clock.elapsed) } }
        clock.onAdvance = { now in
            if let (text, _) = pending.take(after: .milliseconds(50), now: now) {
                accessibility.nodes["field"]?.values["AXValue"] = .string(text + " world")
            }
        }
        #expect(await rig.replace() == .replaced)
        #expect(rig.pasteboard.string() == "the user's own copy")
    }

    @Test("verification: unchanged after ⌘V is unconfirmed; an unreadable value is merely pasted")
    func verification() async {
        let unchanged = Rig()
        unchanged.keys.onPost = { _ in }
        #expect(await unchanged.replace() == .pastedUnconfirmed)

        let unreadable = Rig()
        unreadable.accessibility.nodes["field"]?.values["AXValue"] = nil
        unreadable.keys.onPost = { _ in }
        #expect(await unreadable.replace() == .pasted)
    }

    @Test("the accessibility-write strategy writes the selected text instead of pasting")
    func accessibilityWrite() async {
        let rig = Rig(strategy: AppStrategy(replaceViaAccessibilityWrite: true, rows: ["test"]))
        #expect(await rig.replace() == .replaced)
        #expect(rig.keys.postedShortcuts.isEmpty)
        #expect(rig.accessibility.writes.first?.text == "Hello")
        #expect(rig.pasteboard.writes.isEmpty, "the clipboard is untouched")
    }

    @Test("a timed-out snapshot read still running: nothing is written, clipboardBusy")
    func clipboardBusy() async {
        let rig = Rig(items: [PasteboardItemData(entries: [.init(type: "com.example.lazy", data: Data([1]))])])
        rig.pasteboard.blockingTypes = ["com.example.lazy"]
        let snapshot = await rig.replacer.takeSnapshot()
        #expect(snapshot.pendingRead != nil)
        #expect(await rig.replace(snapshot: snapshot) == .clipboardBusy)
        #expect(rig.pasteboard.writes.isEmpty)
        rig.pasteboard.release.signal()
        if let pending = snapshot.pendingRead { _ = await pending.finished() }
    }

    /// A layout source whose answers each test sets.
    struct FakeLayout: KeyboardLayoutSource {
        var current: [Character: CGKeyCode] = [:]
        var ascii: [Character: CGKeyCode] = [:]
        func currentLayoutKeyCode(for letter: Character) async -> CGKeyCode? { current[letter] }
        func asciiCapableLayoutKeyCode(for letter: Character) async -> CGKeyCode? { ascii[letter] }
    }

    @Test("⌘C and ⌘V key codes: the current layout's ⌘ layer, then the ASCII-capable layout, then ANSI")
    func layoutFallbacks() async {
        // "Dvorak – QWERTY ⌘": with ⌘ held, V is on the QWERTY position.
        #expect(await KeyboardLayout.commandKeyCode(for: "v", source: FakeLayout(current: ["v": 9])) == 9)
        // Cyrillic: no key yields "v"; the ASCII-capable layout does.
        #expect(await KeyboardLayout.commandKeyCode(for: "v", source: FakeLayout(ascii: ["v": 47])) == 47)
        // Neither: the ANSI position.
        #expect(await KeyboardLayout.commandKeyCode(for: "c", source: FakeLayout()) == 8)
        #expect(await KeyboardLayout.commandKeyCode(for: "v", source: FakeLayout()) == 9)
    }
}

/// A paste the fake host applies some time after ⌘V.
final class PendingPaste: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (String, Duration)?

    func set(_ text: String?, at time: Duration) { lock.withLock { value = text.map { ($0, time) } } }

    func take(after delay: Duration, now: Duration) -> (String, Duration)? {
        lock.withLock {
            guard let current = value, now - current.1 >= delay else { return nil }
            value = nil
            return current
        }
    }
}
