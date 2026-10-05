import AppKit
import SelectionKit
import Testing

@testable import Quill

@Suite("Word diff")
struct WordDiffTests {
    @Test("the result joins back exactly; the original keeps its words")
    func roundTrip() {
        let old = "the meeting is moved  to friday\nsee u"
        let new = "The meeting has moved to Friday.\nSee you"
        let segments = WordDiff.segments(from: old, to: new)
        // Unchanged words are shown with the result's spacing, so only the result is exact.
        #expect(segments.filter { $0.kind != .removed }.map(\.text).joined() == new)
        let words = { (text: String) in text.split(whereSeparator: \.isWhitespace) }
        #expect(words(segments.filter { $0.kind != .added }.map(\.text).joined()) == words(old))
    }

    @Test("unchanged words stay, changed ones are removed and added")
    func marksChanges() {
        let segments = WordDiff.segments(from: "see you on monday", to: "see you on Tuesday")
        #expect(segments == [
            .init(text: "see you on ", kind: .same),
            .init(text: "monday", kind: .removed),
            .init(text: "Tuesday", kind: .added),
        ])
        #expect(WordDiff.segments(from: "same text", to: "same text") == [.init(text: "same text", kind: .same)])
    }
}

@Suite("Picker keys")
@MainActor
struct PickerKeyTests {
    private func event(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    @Test("PRODUCT §4.1's keys")
    func keys() throws {
        let cases: [(UInt16, String, NSEvent.ModifierFlags, PickerKey?)] = [
            (36, "\r", [], .returnKey), (36, "\r", .command, .commandReturn), (36, "\r", .option, .optionReturn),
            (76, "\r", [], .returnKey), (53, "\u{1b}", [], .escape), (48, "\t", [], .tab),
            (8, "c", .command, .commandC), (14, "e", .command, .commandE), (2, "d", .command, .d), (15, "r", .command, .r),
            (18, "1", [], .number(1)), (25, "9", [], .number(9)), (29, "0", [], nil),
            // Plain letters are typing in the instruction field, never picker keys.
            (8, "c", [], nil), (2, "d", [], nil), (15, "r", [], nil), (36, "\r", .shift, nil),
        ]
        for (code, characters, flags, expected) in cases {
            #expect(PickerController.key(for: try event(code, characters, flags), correcting: false) == expected,
                    "\(code) \(characters) \(flags)")
        }
    }

    @Test("with a draft in the field, digits are typing; with a selection in it, ⌘C copies the selection")
    func instructionFieldKeys() throws {
        #expect(PickerController.key(for: try event(18, "1"), correcting: false, draftIsEmpty: false) == nil)
        #expect(PickerController.key(for: try event(36, "\r"), correcting: false, draftIsEmpty: false) == .returnKey,
                "Return still reaches the session, which sends the pending instruction")
        #expect(PickerController.key(for: try event(53, "\u{1b}"), correcting: false, draftIsEmpty: false) == .escape)
        #expect(PickerController.key(for: try event(8, "c", .command), correcting: false, fieldHasSelection: true) == nil)
        #expect(PickerController.key(for: try event(8, "c", .command), correcting: false, fieldHasSelection: false) == .commandC)
    }

    @Test("while correcting, only ⌘Return and Esc reach the session")
    func correctingKeys() throws {
        #expect(PickerController.key(for: try event(36, "\r", .command), correcting: true) == .commandReturn)
        #expect(PickerController.key(for: try event(53, "\u{1b}"), correcting: true) == .escape)
        let typing: [(UInt16, String, NSEvent.ModifierFlags)] = [(36, "\r", []), (2, "d", []), (18, "1", []),
                                          (48, "\t", []), (8, "c", .command), (36, "\r", .option)]
        for (code, characters, flags) in typing {
            #expect(PickerController.key(for: try event(code, characters, flags), correcting: true) == nil)
        }
    }
}

@Suite("Toast")
@MainActor
struct ToastTests {
    @Test("every outcome has a line; a direct apply names the profile and ⌘Z")
    func lines() {
        let outcomes: [AppliedOutcome] = [.copied] + [ReplaceOutcome.replaced, .pasted, .pastedUnconfirmed,
            .pastedClipboardHoldsRewrite, .copiedSelectionChanged, .copiedFocusNotReturned, .copiedNotEditable,
            .clipboardBusy].map(AppliedOutcome.replace)
        for outcome in outcomes {
            #expect(!ToastController.text(for: outcome, profile: "Work", direct: false).hasPrefix("toast."), "\(outcome)")
        }
        let direct = ToastController.text(for: .replace(.replaced), profile: "Work", direct: true)
        #expect(direct.contains("Work") && direct.contains("⌘Z"))
    }
}
