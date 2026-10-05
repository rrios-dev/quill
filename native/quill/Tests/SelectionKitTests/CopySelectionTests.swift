import CoreGraphics
import Foundation
import Testing

@testable import SelectionKit

/// A pasteboard whose host clears it first and writes the text a few reads later — the
/// order Mail was measured to use.
private final class SlowHostPasteboard: PasteboardClient, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 1
    private var text: String?
    private var readsUntilText = 0
    var access: PasteboardAccess = .alwaysAllow

    /// What the host does when it receives ⌘C.
    func hostCopies(_ copied: String, afterReads reads: Int) {
        lock.withLock {
            count += 1
            text = nil
            readsUntilText = reads
            pendingText = copied
        }
    }
    private var pendingText: String?

    func changeCount() -> Int { lock.withLock { count } }
    func accessBehavior() -> PasteboardAccess { access }
    func itemTypes() -> [[String]] { [] }
    func data(forType type: String, item index: Int) -> Data? { nil }
    func string() -> String? {
        lock.withLock {
            if text == nil, let pendingText {
                if readsUntilText == 0 { text = pendingText } else { readsUntilText -= 1 }
            }
            return text
        }
    }
    func write(_ items: [PasteboardItemData], hostOnly: Bool) -> Int { lock.withLock { count += 1; return count } }
}

private struct ScriptedKeys: KeyEventPoster {
    let onCommand: @Sendable (Character) -> Void
    func postCommandShortcut(_ letter: Character) async -> Bool { onCommand(letter); return true }
    func isKeyDown(_ keyCode: CGKeyCode) -> Bool { false }
    func heldModifiers() -> HeldModifiers { [] }
}

@Suite("⌘C read")
struct CopySelectionTests {
    private func operations(_ pasteboard: SlowHostPasteboard, copies text: String?, afterReads reads: Int = 0) -> SelectionOperations {
        SelectionOperations(
            accessibility: LiveAccessibilityClient(),
            pasteboard: pasteboard,
            keys: ScriptedKeys { letter in
                if letter == "c", let text { pasteboard.hostCopies(text, afterReads: reads) }
            }
        )
    }

    @Test("a host that clears the pasteboard before writing the text is still read")
    func clearThenWrite() async {
        let pasteboard = SlowHostPasteboard()
        let outcome = await operations(pasteboard, copies: "selected words", afterReads: 3)
            .copySelection(phase: .milliseconds(200), clock: ManualClock())
        #expect(outcome == .copied("selected words"))
    }

    @Test("a host that does not react to ⌘C yields no change")
    func noReaction() async {
        let outcome = await operations(SlowHostPasteboard(), copies: nil)
            .copySelection(phase: .milliseconds(40), clock: ManualClock())
        #expect(outcome == .noChange)
    }

    @Test("without Always Allow nothing is posted or read")
    func needsAlwaysAllow() async {
        let pasteboard = SlowHostPasteboard()
        pasteboard.access = .ask
        let outcome = await operations(pasteboard, copies: "selected words")
            .copySelection(phase: .milliseconds(40), clock: ManualClock())
        #expect(outcome == .readingNotAllowed)
        #expect(pasteboard.changeCount() == 1)
    }
}
