import Foundation
import Synchronization
import Testing

@testable import RemoteTyping

/// A keyboard whose answers the test sets, recording what it was asked.
final class FakeRemoteKeyboard: RemoteKeyboard {
    private struct State {
        var statuses: [RemoteStatus]
        var typeAnswer: RemoteRefusal?
        var selection: RemoteSelection
        var statusAsked = 0
        var selectionAsked: [RemoteComputer] = []
        var typed: [(text: String, computer: RemoteComputer)] = []
        var holds: [Bool] = []
        var reserved: [[RemoteChord]] = []
    }

    private let state: Mutex<State>

    /// Successive `status` answers; the last one repeats.
    init(_ statuses: RemoteStatus..., typeAnswer: RemoteRefusal? = nil, selection: RemoteSelection = .text("")) {
        state = Mutex(State(statuses: statuses, typeAnswer: typeAnswer, selection: selection))
    }

    var statusAsked: Int { state.withLock { $0.statusAsked } }
    var selectionAsked: [RemoteComputer] { state.withLock { $0.selectionAsked } }
    var typed: [String] { state.withLock { $0.typed.map(\.text) } }
    var typedOn: [RemoteComputer] { state.withLock { $0.typed.map(\.computer) } }
    var holds: [Bool] { state.withLock { $0.holds } }
    var reserved: [[RemoteChord]] { state.withLock { $0.reserved } }
    func answerTyping(with refusal: RemoteRefusal?) { state.withLock { $0.typeAnswer = refusal } }

    func selection(on computer: RemoteComputer) async -> RemoteSelection {
        state.withLock { state in
            state.selectionAsked.append(computer)
            return state.selection
        }
    }

    func holdKeyboard(_ hold: Bool) { state.withLock { $0.holds.append(hold) } }
    func reserve(_ chords: [RemoteChord]) { state.withLock { $0.reserved.append(chords) } }
    var reservation: RemoteReservation { .none }

    func status() async -> RemoteStatus {
        state.withLock { state in
            state.statusAsked += 1
            return state.statuses.count > 1 ? state.statuses.removeFirst() : state.statuses[0]
        }
    }

    func type(_ text: String, on computer: RemoteComputer) async -> RemoteRefusal? {
        state.withLock { state in
            state.typed.append((text, computer))
            return state.typeAnswer
        }
    }
}

private let linux = RemoteComputer(id: "linux", name: "Workstation Linux")

/// Where a ready text lands: on the computer with the keyboard, or on this Mac (S6 R2).
@Suite("Remote landing")
struct RemoteLandingTests {
    @Test("with the keyboard on a client, the text is typed there and nothing is inserted on the Mac")
    func typedOnTheClient() async {
        let keyboard = FakeRemoteKeyboard(.client(linux))
        let landing = RemoteLanding(keyboard: keyboard)
        #expect(await landing.land("hola desde el Mac") == .typed(computer: "Workstation Linux"))
        #expect(keyboard.typed == ["hola desde el Mac"])
        #expect(keyboard.typedOn == [linux])
    }

    @Test("with the keyboard on the Mac, or no Batuta, the text is inserted locally and nothing is said")
    func localWithoutNotice() async {
        for status in [RemoteStatus.mac, .absent] {
            let keyboard = FakeRemoteKeyboard(status)
            let landing = RemoteLanding(keyboard: keyboard)
            #expect(await landing.land("texto") == .local(notice: nil))
            #expect(keyboard.typed.isEmpty)
        }
    }

    @Test("Batuta is asked when each text is ready, never from an earlier answer")
    func askedEveryTime() async {
        let keyboard = FakeRemoteKeyboard(.mac, .client(linux), .mac)
        let landing = RemoteLanding(keyboard: keyboard)
        #expect(await landing.land("uno") == .local(notice: nil))
        #expect(await landing.land("dos") == .typed(computer: "Workstation Linux"))
        #expect(await landing.land("tres") == .local(notice: nil))
        #expect(keyboard.statusAsked == 3)
        #expect(keyboard.typed == ["dos"])
    }

    @Test("a refused status inserts locally and is said once, not on every text",
          arguments: [RemoteRefusal.accessOff, .refused, .untrustedServer, .noAnswer])
    func refusedStatusSaidOnce(_ refusal: RemoteRefusal) async {
        let keyboard = FakeRemoteKeyboard(.refused(refusal))
        let landing = RemoteLanding(keyboard: keyboard)
        #expect(await landing.land("uno") == .local(notice: refusal))
        #expect(await landing.land("dos") == .local(notice: nil))
        #expect(keyboard.typed.isEmpty)
    }

    @Test("a client that does not take the text leaves it on the Mac, said once")
    func clientCannotType() async {
        let keyboard = FakeRemoteKeyboard(.client(linux), typeAnswer: .cannotType(computer: "Workstation Linux"))
        let landing = RemoteLanding(keyboard: keyboard)
        #expect(await landing.land("uno") == .local(notice: .cannotType(computer: "Workstation Linux")))
        #expect(await landing.land("dos") == .local(notice: nil))
    }

    @Test("a different refusal is said, and after a text reaches the client the same refusal is said again")
    func saidAgainWhenSomethingChanged() async {
        let keyboard = FakeRemoteKeyboard(.refused(.accessOff), .refused(.noAnswer), .refused(.accessOff),
                                          .client(linux), .refused(.accessOff))
        let landing = RemoteLanding(keyboard: keyboard)
        #expect(await landing.land("1") == .local(notice: .accessOff))
        #expect(await landing.land("2") == .local(notice: .noAnswer))
        #expect(await landing.land("3") == .local(notice: .accessOff))
        #expect(await landing.land("4") == .typed(computer: "Workstation Linux"))
        #expect(await landing.land("5") == .local(notice: .accessOff))
    }
}

private let mac2 = RemoteComputer(id: "air", name: "MacBook Air")

/// The shortcut on another computer's selection (S6 R6): Quill works on that text as on the
/// Mac's, and types the result back only where it came from.
@Suite("Remote landing: a text from another computer")
struct RemoteSourceTests {
    @Test("with the keyboard on a client, the shortcut's text is that client's selection")
    func clientSelection() async {
        let keyboard = FakeRemoteKeyboard(.client(linux), selection: .text("hola mundo"))
        let landing = RemoteLanding(keyboard: keyboard)
        #expect(await landing.source() == .client(linux, text: "hola mundo"))
        #expect(keyboard.selectionAsked == [linux])
    }

    @Test("with the keyboard on the Mac, no Batuta, or a Batuta that will not say, the Mac's selection is used",
          arguments: [RemoteStatus.mac, .absent, .refused(.accessOff), .refused(.untrustedServer), .refused(.noAnswer)])
    func macSelection(_ status: RemoteStatus) async {
        let keyboard = FakeRemoteKeyboard(status, selection: .text("no debe leerse"))
        #expect(await RemoteLanding(keyboard: keyboard).source() == .mac)
        #expect(keyboard.selectionAsked.isEmpty)
    }

    @Test("nothing selected there, blanks included, is said; the Mac's selection is never used instead",
          arguments: ["", "  \n\t "])
    func nothingSelected(_ text: String) async {
        let keyboard = FakeRemoteKeyboard(.client(linux), selection: .text(text))
        #expect(await RemoteLanding(keyboard: keyboard).source()
            == .nothing(.nothingSelected(computer: "Workstation Linux")))
    }

    @Test("a selection that cannot be read, or a refusal, is said as such")
    func unreadableOrRefused() async {
        let unreadable = FakeRemoteKeyboard(.client(linux), selection: .unreadable)
        #expect(await RemoteLanding(keyboard: unreadable).source() == .nothing(.unreadable(computer: "Workstation Linux")))
        let off = FakeRemoteKeyboard(.client(linux), selection: .refused(.accessOff))
        #expect(await RemoteLanding(keyboard: off).source() == .nothing(.refused(.accessOff)))
        let moved = FakeRemoteKeyboard(.client(linux), selection: .refused(.focusMoved(computer: "Workstation Linux")))
        #expect(await RemoteLanding(keyboard: moved).source()
            == .nothing(.refused(.focusMoved(computer: "Workstation Linux"))))
    }

    @Test("the result is typed back on the computer it came from")
    func typedBack() async {
        let keyboard = FakeRemoteKeyboard(.client(linux))
        #expect(await RemoteLanding(keyboard: keyboard).land("Hola, mundo.", on: linux) == nil)
        #expect(keyboard.typed == ["Hola, mundo."])
        #expect(keyboard.typedOn == [linux])
    }

    @Test("if the keyboard moved to the Mac or to another computer meanwhile, nothing is typed anywhere",
          arguments: [RemoteStatus.mac, .client(mac2)])
    func focusMoved(_ status: RemoteStatus) async {
        let keyboard = FakeRemoteKeyboard(status)
        #expect(await RemoteLanding(keyboard: keyboard).land("texto", on: linux)
            == .focusMoved(computer: "Workstation Linux"))
        #expect(keyboard.typed.isEmpty)
    }

    @Test("a refusal for a text from another computer is said every time: the owner looks for it there")
    func refusalSaidEveryTime() async {
        let keyboard = FakeRemoteKeyboard(.client(linux), typeAnswer: .cannotType(computer: "Workstation Linux"))
        let landing = RemoteLanding(keyboard: keyboard)
        #expect(await landing.land("uno", on: linux) == .cannotType(computer: "Workstation Linux"))
        #expect(await landing.land("dos", on: linux) == .cannotType(computer: "Workstation Linux"))
        let gone = FakeRemoteKeyboard(.absent)
        #expect(await RemoteLanding(keyboard: gone).land("tres", on: linux) == .noAnswer)
        let off = FakeRemoteKeyboard(.refused(.accessOff))
        #expect(await RemoteLanding(keyboard: off).land("cuatro", on: linux) == .accessOff)
    }

    @Test("the hold reaches the keyboard in the order it was asked")
    func holdInOrder() {
        let keyboard = FakeRemoteKeyboard(.client(linux))
        let landing = RemoteLanding(keyboard: keyboard)
        landing.hold(true)
        landing.hold(false)
        #expect(keyboard.holds == [true, false])
    }
}
