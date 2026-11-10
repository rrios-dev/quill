import AppCore
import Carbon.HIToolbox
import Foundation
import ModelKit
import RemoteTyping
import SelectionKit
import Synchronization
import Testing

@testable import Quill

/// Batuta's keyboard as a test sets it: where it is, and whether the client takes the text.
final class FakeBatuta: RemoteKeyboard {
    private struct State {
        var status: RemoteStatus
        var refusal: RemoteRefusal?
        var selection: RemoteSelection
        var typed: [String] = []
        var typedOn: [RemoteComputer] = []
        var asked = 0
        var holds: [Bool] = []
        /// The status `type` moves the keyboard to before it answers (the owner moving it meanwhile).
        var moveWhileTyping: RemoteStatus?
    }

    private let state: Mutex<State>

    init(_ status: RemoteStatus, refusal: RemoteRefusal? = nil, selection: RemoteSelection = .text("")) {
        state = Mutex(State(status: status, refusal: refusal, selection: selection))
    }

    var typed: [String] { state.withLock { $0.typed } }
    var typedOn: [RemoteComputer] { state.withLock { $0.typedOn } }
    var asked: Int { state.withLock { $0.asked } }
    var holds: [Bool] { state.withLock { $0.holds } }
    var isHeld: Bool { holds.last == true }
    func move(to status: RemoteStatus) { state.withLock { $0.status = status } }
    func answerTyping(with refusal: RemoteRefusal?) { state.withLock { $0.refusal = refusal } }

    func status() async -> RemoteStatus {
        state.withLock { state in
            state.asked += 1
            return state.status
        }
    }

    func type(_ text: String, on computer: RemoteComputer) async -> RemoteRefusal? {
        state.withLock { state in
            if state.refusal == nil {
                state.typed.append(text)
                state.typedOn.append(computer)
            }
            return state.refusal
        }
    }

    func selection(on computer: RemoteComputer) async -> RemoteSelection { state.withLock { $0.selection } }
    func holdKeyboard(_ hold: Bool) { state.withLock { $0.holds.append(hold) } }
    func reserve(_ chords: [RemoteChord]) {}
    var reservation: RemoteReservation { .none }
}

private let linux = RemoteComputer(id: "linux", name: "Workstation Linux")
private let result = "The meeting has moved to Friday."

/// Quill's text on the computer Batuta lends the keyboard to (shared-control S6 R2): when the
/// result is applied, it lands where the keyboard is. The shortcut fires with the keyboard on
/// the Mac (a text of the Mac); since R6, a shortcut that fires with the keyboard on a client
/// takes that client's selection instead (`RemoteSelectionSessionTests`).
@MainActor
@Suite("Rewrite session: the keyboard on another computer")
struct RemoteTypingSessionTests {
    @Test("with the keyboard on a client, Return types the result there and the Mac's selection is left alone")
    func typedOnTheClient() async throws {
        let batuta = FakeBatuta(.mac)
        let harness = try SessionHarness(remote: RemoteLanding(keyboard: batuta))
        await harness.start()
        batuta.move(to: .client(linux))
        await harness.press(.returnKey)
        #expect(batuta.typed == [result])
        #expect(harness.selection.replaced.isEmpty)
        #expect(harness.effects.suffix(2) == [.close, .toast(.typed(computer: "Workstation Linux"), profile: "Test", direct: false)])
    }

    @Test("Batuta is asked when the result is applied, not when the rewrite started")
    func askedAtApply() async throws {
        let batuta = FakeBatuta(.mac)
        let harness = try SessionHarness(remote: RemoteLanding(keyboard: batuta))
        await harness.start()
        #expect(batuta.asked == 1, "once, when the shortcut fired: where the text comes from (R6)")
        batuta.move(to: .client(linux))
        await harness.press(.returnKey)
        #expect(batuta.asked == 2)
        #expect(batuta.typed == [result])
    }

    @Test("with the keyboard on the Mac, or no Batuta, the result replaces the selection as always", arguments: [
        RemoteStatus.mac, .absent,
    ])
    func localAsAlways(_ status: RemoteStatus) async throws {
        let batuta = FakeBatuta(status)
        let harness = try SessionHarness(remote: RemoteLanding(keyboard: batuta))
        await harness.start()
        await harness.press(.returnKey)
        #expect(batuta.typed.isEmpty)
        #expect(harness.selection.replaced.map(\.text) == [result])
        #expect(harness.effects.suffix(2) == [.close, .toast(.replace(.replaced), profile: "Test", direct: false)])
    }

    @Test("a refusal keeps the result on the Mac and is said once, in the toast, not on the next rewrite")
    func refusalSaidOnce() async throws {
        let batuta = FakeBatuta(.mac, refusal: .cannotType(computer: "Workstation Linux"))
        let landing = RemoteLanding(keyboard: batuta)
        let first = try SessionHarness(remote: landing)
        await first.start()
        batuta.move(to: .client(linux))
        await first.press(.returnKey)
        #expect(first.selection.replaced.map(\.text) == [result])
        #expect(first.effects.last == .toast(.replace(.replaced), profile: "Test", direct: false,
                                            remote: .cannotType(computer: "Workstation Linux")))

        let second = try SessionHarness(remote: landing)
        batuta.move(to: .mac)
        await second.start()
        batuta.move(to: .client(linux))
        await second.press(.returnKey)
        #expect(second.selection.replaced.map(\.text) == [result])
        #expect(second.effects.last == .toast(.replace(.replaced), profile: "Test", direct: false))
    }

    @Test("an app Quill would only copy into does not matter when the keyboard is on another computer")
    func uncertainTargetStillTyped() async throws {
        let batuta = FakeBatuta(.mac)
        let harness = try SessionHarness(capture: SessionHarness.capture(editability: .uncertain),
                                         remote: RemoteLanding(keyboard: batuta))
        await harness.start()
        batuta.move(to: .client(linux))
        await harness.press(.returnKey)
        #expect(batuta.typed == [result])
        #expect(harness.selection.copied.isEmpty && harness.selection.replaced.isEmpty)
    }

    @Test("⌘C still copies, wherever the keyboard is")
    func copyStaysCopy() async throws {
        let batuta = FakeBatuta(.mac)
        let harness = try SessionHarness(remote: RemoteLanding(keyboard: batuta))
        await harness.start()
        batuta.move(to: .client(linux))
        await harness.press(.commandC)
        #expect(batuta.asked == 1, "only when the shortcut fired")
        #expect(harness.selection.copied == [result])
    }

    @Test("the toast names the computer the text went to, and each refusal in Quill's words", arguments: [
        RemoteRefusal.accessOff, .refused, .untrustedServer, .noAnswer, .cannotType(computer: "Workstation Linux"),
    ])
    func toastText(_ refusal: RemoteRefusal) {
        let typed = ToastController.text(for: .typed(computer: "Workstation Linux"), profile: "Test", direct: false)
        #expect(typed.contains("Workstation Linux"))
        let notice = ToastController.text(for: .replace(.replaced), profile: "Test", direct: false, remote: refusal)
        let plain = ToastController.text(for: .replace(.replaced), profile: "Test", direct: false)
        #expect(notice.hasPrefix(plain) && notice.count > plain.count + 10)
        #expect(!notice.contains("Agent access"), "Batuta's English sentence is never shown")
    }
}

/// Quill on the other computer's text (shared-control S6 R6, J-19 "igual que en el Mac"): the
/// shortcut takes that computer's selection, the picker gets the keys while it is open, and
/// the result is typed back over that selection.
@MainActor
@Suite("Rewrite session: a selection on another computer")
struct RemoteSelectionSessionTests {
    private func onLinux(_ selection: RemoteSelection = .text(SessionHarness.input)) -> FakeBatuta {
        FakeBatuta(.client(linux), selection: selection)
    }

    @Test("the shortcut takes the other computer's selection, never the Mac's, and Return types the result back there")
    func rewritesTheRemoteSelection() async throws {
        let batuta = onLinux()
        let harness = try SessionHarness(remote: RemoteLanding(keyboard: batuta))
        await harness.start()
        #expect(harness.selection.captures == 0)
        #expect(harness.selection.snapshots == 0, "nothing will be pasted on this Mac")
        #expect(harness.session.capture?.text == SessionHarness.input)
        #expect(harness.session.remoteSource == linux)
        #expect(harness.session.state == .ready(text: result))
        await harness.press(.returnKey)
        #expect(batuta.typed == [result])
        #expect(batuta.typedOn == [linux])
        #expect(harness.selection.replaced.isEmpty && harness.selection.copied.isEmpty)
        #expect(harness.effects.suffix(2) == [.close, .toast(.typed(computer: "Workstation Linux"), profile: "Test", direct: false)])
    }

    @Test("while the picker is open the keys stay on the Mac, and they go back before the text is typed")
    func holdsWhileThePickerIsOpen() async throws {
        let batuta = onLinux()
        let harness = try SessionHarness(remote: RemoteLanding(keyboard: batuta))
        await harness.start()
        #expect(harness.effects.first == .showPicker)
        #expect(batuta.holds == [true])
        await harness.press(.returnKey)
        #expect(batuta.holds == [true, false])
    }

    @Test("Escape, the shortcut again or ⌘C give the keys back", arguments: [PickerKey.escape, .shortcut, .commandC])
    func releasedOnClose(_ key: PickerKey) async throws {
        let batuta = onLinux()
        let harness = try SessionHarness(remote: RemoteLanding(keyboard: batuta))
        await harness.start()
        await harness.press(key)
        #expect(batuta.holds == [true, false])
        #expect(!batuta.isHeld)
        #expect(batuta.typed.isEmpty)
    }

    @Test("a failure keeps the picker and the keys until the owner closes it, then gives them back")
    func releasedAfterAFailure() async throws {
        let batuta = onLinux()
        let harness = try SessionHarness(remote: RemoteLanding(keyboard: batuta))
        harness.local.error = ProviderError(.authentication, "bad key")
        await harness.start()
        guard case .failed = harness.session.state else {
            Issue.record("expected a failure, got \(harness.session.state)")
            return
        }
        #expect(batuta.isHeld)
        await harness.press(.escape)
        #expect(!batuta.isHeld)
    }

    @Test("nothing selected there, or a selection Batuta will not give, is said alone: no capture on the Mac, no picker, no hold")
    func nothingToRewrite() async throws {
        let cases: [(RemoteSelection, RemoteLanding.SelectionNotice)] = [
            (.text("   "), .nothingSelected(computer: "Workstation Linux")),
            (.unreadable, .unreadable(computer: "Workstation Linux")),
            (.refused(.accessOff), .refused(.accessOff)),
            (.refused(.noAnswer), .refused(.noAnswer)),
            (.refused(.untrustedServer), .refused(.untrustedServer)),
        ]
        for (selection, notice) in cases {
            let batuta = onLinux(selection)
            let harness = try SessionHarness(remote: RemoteLanding(keyboard: batuta))
            await harness.start()
            #expect(harness.effects == [.selectionNotice(notice)])
            #expect(harness.session.state == .closed)
            #expect(harness.selection.captures == 0)
            #expect(harness.streams == 0)
            #expect(batuta.holds.isEmpty)
        }
    }

    @Test("if the keyboard left that computer before Return, nothing is typed anywhere: the result is copied and the toast says why",
          arguments: [RemoteStatus.mac, .client(RemoteComputer(id: "air", name: "MacBook Air"))])
    func focusMovedMeanwhile(_ moved: RemoteStatus) async throws {
        let batuta = onLinux()
        let harness = try SessionHarness(remote: RemoteLanding(keyboard: batuta))
        await harness.start()
        batuta.move(to: moved)
        await harness.press(.returnKey)
        #expect(batuta.typed.isEmpty)
        #expect(harness.selection.replaced.isEmpty)
        #expect(harness.selection.copied == [result])
        #expect(harness.effects.last == .toast(.copied, profile: "Test", direct: false,
                                               remote: .focusMoved(computer: "Workstation Linux")))
        #expect(!batuta.isHeld)
    }

    @Test("a refusal to type keeps the result on the clipboard and says why, every time")
    func refusedTyping() async throws {
        let batuta = onLinux()
        batuta.answerTyping(with: .cannotType(computer: "Workstation Linux"))
        let landing = RemoteLanding(keyboard: batuta)
        for _ in 0..<2 {
            let harness = try SessionHarness(remote: landing)
            await harness.start()
            await harness.press(.returnKey)
            #expect(harness.selection.copied == [result])
            #expect(harness.effects.last == .toast(.copied, profile: "Test", direct: false,
                                                   remote: .cannotType(computer: "Workstation Linux")))
        }
    }

    @Test("Batuta's row in Settings → Apps gives the other computers' texts a profile and direct apply, like any app")
    func directApplyThroughBatutasRow() async throws {
        let batuta = onLinux()
        let harness = try SessionHarness(remote: RemoteLanding(keyboard: batuta))
        let testID = harness.test.id
        try harness.settings.update {
            $0.appDefaults[BatutaKeyboard.bundleIdentifier] = testID
            $0.directApplyApps.insert(BatutaKeyboard.bundleIdentifier)
        }
        await harness.start()
        try await waitUntil { kind(harness.session.state) == "applied" }
        #expect(!harness.effects.contains(.showPicker))
        #expect(batuta.holds.isEmpty)
        #expect(batuta.typed == [result])
        #expect(harness.effects.last == .toast(.typed(computer: "Workstation Linux"), profile: "Test", direct: true))
    }

    @Test("with the keyboard on the Mac the shortcut captures the Mac's selection as always, and holds nothing")
    func macAsAlways() async throws {
        let batuta = FakeBatuta(.mac, selection: .text("never read"))
        let harness = try SessionHarness(remote: RemoteLanding(keyboard: batuta))
        await harness.start()
        #expect(harness.selection.captures == 1)
        #expect(harness.session.remoteSource == nil)
        await harness.press(.returnKey)
        #expect(harness.selection.replaced.map(\.text) == [result])
        #expect(batuta.holds.isEmpty)
    }

    @Test("the toast says each reason in Quill's words, in Spanish and English alike", arguments: [
        RemoteLanding.SelectionNotice.nothingSelected(computer: "Workstation Linux"), .unreadable(computer: "Workstation Linux"),
        .refused(.accessOff), .refused(.refused), .refused(.untrustedServer), .refused(.noAnswer),
        .refused(.focusMoved(computer: "Workstation Linux")),
    ])
    func selectionNoticeText(_ notice: RemoteLanding.SelectionNotice) {
        let text = ToastController.selectionNotice(notice)
        #expect(text.count > 10)
        #expect(!text.hasPrefix("toast."), "a key without a value")
        if case .nothingSelected = notice { #expect(text.contains("Workstation Linux")) }
        let moved = ToastController.text(for: .copied, profile: "Test", direct: false,
                                         remote: .focusMoved(computer: "Workstation Linux"))
        #expect(moved.contains("Workstation Linux"))
    }
}

/// Quill's shortcut, kept on the Mac by Batuta while another computer has the keyboard (S6 R6).
@MainActor
@Suite("Shortcut reserved with Batuta")
struct ReservedShortcutTests {
    @Test("a registered shortcut is reserved with its key code and named modifiers")
    func registered() {
        let controller = HotKeyController(register: { _, _, _ in .success(1) }, unregister: { _ in })
        controller.register(KeyCombination(keyCode: 15, modifiers: UInt32(controlKey | optionKey))) {}
        #expect(controller.reservedChords == [RemoteChord(keyCode: 15, modifiers: [.control, .option])])
        controller.register(KeyCombination(keyCode: 46, modifiers: UInt32(cmdKey | shiftKey))) {}
        #expect(controller.reservedChords == [RemoteChord(keyCode: 46, modifiers: [.command, .shift])])
    }

    @Test("a shortcut that did not register is not taken from the other computer's apps")
    func notRegistered() {
        let controller = HotKeyController(register: { _, _, _ in .failure(HotKeyRegistrationError(status: -9878)) },
                                          unregister: { _ in })
        controller.register(HotKeyController.defaultShortcut) {}
        #expect(controller.reservedChords.isEmpty)
        #expect(HotKeyController().reservedChords.isEmpty)
    }

    @Test("the menu says why when Batuta turned the shortcut down, and nothing otherwise")
    func menuNote() {
        #expect(AppDelegate.batutaNote(.none) == nil)
        #expect(AppDelegate.batutaNote(.reserved) == nil)
        for refusal in [RemoteRefusal.accessOff, .refused, .untrustedServer, .noAnswer] {
            let note = AppDelegate.batutaNote(.refused(refusal))
            #expect(note.map { $0.count > 20 && !$0.hasPrefix("menu.") } == true)
        }
        #expect(AppDelegate.batutaNote(.refused(.accessOff)) != AppDelegate.batutaNote(.refused(.noAnswer)))
    }
}
