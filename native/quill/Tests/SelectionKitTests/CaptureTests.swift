import CoreGraphics
import Foundation
import Testing

@testable import SelectionKit

/// The capture sequence on fakes (PLAN P2-T2, ARCHITECTURE §3.1).
@Suite("Capture sequence")
struct CaptureTests {
    let app = AppIdentity(pid: 7, bundleIdentifier: "com.example.editor")

    struct Rig {
        let log = EffectLog()
        let clock: ManualClock
        let accessibility: FakeAccessibility
        let pasteboard: FakePasteboard
        let keys: FakeKeys
        let capturer: SelectionCapturer

        init(strategy: AppStrategy = .default, settings: CaptureSettings = CaptureSettings(),
             access: PasteboardAccess = .alwaysAllow) {
            clock = ManualClock(log: log)
            accessibility = FakeAccessibility(log: log)
            pasteboard = FakePasteboard(items: [textItem("the user's own copy")], access: access, log: log)
            keys = FakeKeys(log: log)
            let operations = SelectionOperations(accessibility: accessibility, pasteboard: pasteboard, keys: keys)
            capturer = SelectionCapturer(operations: operations, settings: settings, strategy: { _ in strategy })
            let pasteboard = pasteboard
            let clock = clock
            let log = log
            keys.onPost = { letter in
                log.append("cmd\(letter) at \(clock.elapsed)")
                if letter == "c" { pasteboard.simulateHostCopy() }
            }
        }

        /// A focused text field holding `text`, with `selected` selected.
        func field(_ name: String = "field", text: String = "hello world", selected: String? = "hello",
                   settable: Bool = true, subrole: String? = nil) {
            var node = FakeAccessibility.Node(pid: 7)
            node.values["AXRole"] = .string("AXTextField")
            if let subrole { node.values["AXSubrole"] = .string(subrole) }
            node.values["AXValue"] = .string(text)
            if let selected {
                node.values["AXSelectedText"] = .string(selected)
                node.values["AXSelectedTextRange"] = .range(CFRange(location: 0, length: selected.count))
            }
            if settable { node.settable = ["AXSelectedText"] }
            node.runs = [AttributeRun(fontName: "Helvetica")]
            node.bounds = CGRect(x: 10, y: 100, width: 50, height: 14)
            accessibility.nodes[name] = node
            accessibility.systemFocus = .success(name)
            accessibility.applicationFocus[7] = .success(name)
        }

        func capture(hotKey: CGKeyCode? = nil) async -> Result<Capture, CaptureRefusal> {
            await capturer.capture(app: AppIdentity(pid: 7, bundleIdentifier: "com.example.editor"),
                                   hotKeyCode: hotKey, primaryScreenHeight: 900, clock: clock)
        }
    }

    @Test("a selection read through accessibility is captured, editable when settable, with bounds and formatting")
    func accessibilityCapture() async throws {
        let rig = Rig()
        rig.field()
        let capture = try await rig.capture().get()
        #expect(capture.text == "hello" && capture.method == .accessibility)
        #expect(capture.editability == .editable)
        #expect(capture.formatting == .plain)
        #expect(capture.bounds == CGRect(x: 10, y: 786, width: 50, height: 14))
        #expect(rig.keys.postedShortcuts.isEmpty)
        #expect(rig.clock.elapsed <= SelectionCapturer.accessibilityPhase)
    }

    @Test("a password field is refused by its subrole, never read")
    func passwordField() async {
        let rig = Rig()
        rig.field(subrole: "AXSecureTextField")
        #expect(await rig.capture().refusal == .passwordField)
        #expect(rig.keys.postedShortcuts.isEmpty)
    }

    @Test("an empty selection in a process not yet switched: manual accessibility, polling to the deadline, then a refusal without ⌘C")
    func emptySelection() async {
        let rig = Rig()
        rig.field(selected: "")
        #expect(await rig.capture().refusal == .noSelection)
        #expect(rig.accessibility.manualAccessibilityRequests == [7])
        #expect(rig.clock.elapsed >= SelectionCapturer.accessibilityPhase, "the poll ran to the phase's deadline")
        #expect(rig.clock.elapsed < SelectionCapturer.accessibilityPhase + .milliseconds(10))
        #expect(rig.keys.postedShortcuts.isEmpty, "never ⌘C for an empty selection")
    }

    @Test("a lazy tree that fills in after manual accessibility is captured through accessibility")
    func lazyTree() async throws {
        let rig = Rig()
        rig.field(selected: "")
        let accessibility = rig.accessibility
        rig.clock.onAdvance = { time in
            if time >= .milliseconds(40), case .string("")? = accessibility.nodes["field"]?.values["AXSelectedText"] {
                accessibility.nodes["field"]?.values["AXSelectedText"] = .string("hello")
                accessibility.nodes["field"]?.values["AXSelectedTextRange"] = .range(CFRange(location: 0, length: 5))
            }
        }
        let capture = try await rig.capture().get()
        #expect(capture.method == .accessibility && capture.text == "hello")
        #expect(rig.clock.elapsed < .milliseconds(60))
    }

    @Test("manual accessibility is set once per process")
    func manualOnce() async {
        let rig = Rig()
        rig.field(selected: "")
        _ = await rig.capture()
        _ = await rig.capture()
        #expect(rig.accessibility.manualAccessibilityRequests == [7])
        rig.capturer.processTerminated(7)
        _ = await rig.capture()
        #expect(rig.accessibility.manualAccessibilityRequests == [7, 7], "a new process with the same pid starts unswitched")
    }

    @Test("not settable is uncertain; the app's editable signal makes it editable")
    func editability() async throws {
        let plain = Rig()
        plain.field(settable: false)
        #expect(try await plain.capture().get().editability == .uncertain)

        let signalled = Rig(strategy: AppStrategy(editableSignal: .settableValue, rows: ["test"]))
        signalled.field(settable: false)
        signalled.accessibility.nodes["field"]?.settable = ["AXValue"]
        #expect(try await signalled.capture().get().editability == .editable)

        let ancestor = Rig(strategy: AppStrategy(editableSignal: .editableAncestor, rows: ["test"]))
        ancestor.field(settable: false)
        ancestor.accessibility.nodes["field"]?.values["AXEditableAncestor"] = .element("field")
        #expect(try await ancestor.capture().get().editability == .editable)
    }

    @Test("terminals are read-only-only, by the denylist and by xterm's helper textarea")
    func terminals() async throws {
        let denylisted = Rig(strategy: AppStrategy.strategy(for: "com.googlecode.iterm2"))
        denylisted.field()
        #expect(try await denylisted.capture().get().editability == .readOnlyOnly)

        let vsCode = Rig()
        vsCode.field()
        vsCode.accessibility.nodes["field"]?.values["AXDOMClassList"] = .strings(["xterm-helper-textarea"])
        #expect(try await vsCode.capture().get().editability == .readOnlyOnly)
    }

    @Test("⌘C only when accessibility is unavailable, after the hot key's release and the modifier wait")
    func copyFallbackOrder() async throws {
        let rig = Rig()
        rig.accessibility.systemFocus = .failure(.cannotComplete)
        rig.accessibility.applicationFocus[7] = .failure(.cannotComplete)
        rig.pasteboard.hostCopy = textItem("selected in an inaccessible app")
        let clock = rig.clock
        rig.keys.keysDown = { code in code == 15 && clock.elapsed < .milliseconds(300) }
        rig.keys.modifiers = { clock.elapsed < .milliseconds(350) ? [.control, .option] : [] }
        let capture = try await rig.capture(hotKey: 15).get()
        #expect(capture.method == .copy && capture.text == "selected in an inaccessible app")
        #expect(capture.editability == .uncertain)
        let posted = rig.log.all.first { $0.hasPrefix("cmdc at ") }
        let time = posted.flatMap { Double($0.split(separator: " ")[2].replacingOccurrences(of: "seconds", with: "")) } ?? 0
        #expect(time >= 0.35, "⌘C after the key and the modifiers came up (posted at \(time) s)")
        #expect(rig.log.happened("pasteboardRead", before: "cmdc"), "the snapshot precedes ⌘C")
        #expect(rig.pasteboard.string() == "the user's own copy", "the user's clipboard is restored")
        #expect(clock.elapsed <= .milliseconds(800))
    }

    @Test("modifiers still held at the cap refuse the capture within 800 ms")
    func modifiersHeld() async {
        let rig = Rig()
        rig.accessibility.systemFocus = .failure(.cannotComplete)
        rig.accessibility.applicationFocus[7] = .failure(.cannotComplete)
        rig.keys.modifiers = { [.shift] }
        #expect(await rig.capture().refusal == .modifiersHeld)
        #expect(rig.keys.postedShortcuts.isEmpty)
        #expect(rig.clock.elapsed <= .milliseconds(800))
    }

    @Test("without Always Allow, or with the fallback off, accessibility-less apps are refused")
    func copyNeedsPermission() async {
        let ask = Rig(access: .ask)
        ask.accessibility.systemFocus = .failure(.attributeUnsupported)
        ask.accessibility.applicationFocus[7] = .failure(.attributeUnsupported)
        #expect(await ask.capture().refusal == .copyNeedsAlwaysAllow)
        #expect(ask.pasteboard.reads == 0)

        let off = Rig(settings: CaptureSettings(copyFallbackEnabled: false))
        off.accessibility.systemFocus = .failure(.attributeUnsupported)
        off.accessibility.applicationFocus[7] = .failure(.attributeUnsupported)
        #expect(await off.capture().refusal == .copyDisabled)
    }

    @Test("the ⌘C-only strategy copies even when accessibility answers, keeping its editable signal (Mail)")
    func copyOnlyStrategy() async throws {
        let rig = Rig(strategy: AppStrategy.strategy(for: "com.apple.mail"))
        rig.field(selected: nil, settable: false)
        rig.accessibility.nodes["field"]?.settable = ["AXValue"]
        rig.pasteboard.hostCopy = textItem("mail body")
        let capture = try await rig.capture().get()
        #expect(capture.method == .copy && capture.text == "mail body")
        #expect(capture.editability == .editable)
    }

    @Test("rich formatting is detected from accessibility runs and from the copied RTF or HTML")
    func richFormatting() async throws {
        let rig = Rig()
        rig.field()
        rig.accessibility.nodes["field"]?.runs = [AttributeRun(fontName: "Helvetica"), AttributeRun(fontName: "Helvetica-Bold")]
        #expect(try await rig.capture().get().formatting == .rich)

        let unanswered = Rig()
        unanswered.field()
        unanswered.accessibility.nodes["field"]?.runs = nil
        #expect(try await unanswered.capture().get().formatting == .unknown)

        let copied = Rig()
        copied.accessibility.systemFocus = .failure(.cannotComplete)
        copied.accessibility.applicationFocus[7] = .failure(.cannotComplete)
        copied.pasteboard.hostCopy = PasteboardItemData(entries: [
            .init(type: "public.utf8-plain-text", data: Data("bold".utf8)),
            .init(type: "public.html", data: Data("<b>bold</b>".utf8)),
        ])
        #expect(try await copied.capture().get().formatting == .rich)
    }

    @Test("an untrusted process captures nothing")
    func untrusted() async {
        let rig = Rig()
        rig.field()
        rig.accessibility.trusted = false
        #expect(await rig.capture().refusal == .notTrusted)
    }
}

extension Result where Failure == CaptureRefusal {
    /// The refusal, or nil when something was captured.
    var refusal: CaptureRefusal? {
        if case .failure(let refusal) = self { return refusal }
        return nil
    }
}
