import AgentHost
import Darwin
import Foundation
import MCPKit
import Synchronization
import Testing

@testable import RemoteTyping

/// Requests a fake wire received, and the answer it gives.
private final class Wire: Sendable {
    let requests = Mutex<[[String: String]]>([])
    private let answer: @Sendable ([String: String]) async throws -> String

    init(_ answer: @escaping @Sendable ([String: String]) async throws -> String) { self.answer = answer }
    convenience init(reply: String) { self.init { _ in reply } }
    convenience init(throwing error: any Error) { self.init { _ in throw error } }

    var exchange: BatutaKeyboard.Exchange {
        { data in
            let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let sent = request.compactMapValues { $0 as? String }
            self.requests.withLock { $0.append(sent) }
            return Data(try await self.answer(sent).utf8)
        }
    }

    var verbs: [String] { requests.withLock { $0.compactMap { $0["verb"] } } }
    var last: [String: String] { requests.withLock { $0.last ?? [:] } }
}

private let statusLinux = #"{"ok":true,"focus":"linux","computers":[{"id":"studio","name":"Mac Studio"},{"id":"linux","name":"Workstation Linux"}]}"#
private let statusStudio = #"{"ok":true,"focus":"studio","computers":[{"id":"studio","name":"Mac Studio"},{"id":"linux","name":"Workstation Linux"}]}"#
private let accessOff = #"{"ok":false,"error":"Agent access is off in Batuta. The user can turn it on in Batuta's window, under Your apps."}"#
private let linux = RemoteComputer(id: "linux", name: "Workstation Linux")

/// Batuta's local API as Quill reads it (`native/batuta/docs/local-api.md`).
@Suite("Batuta keyboard: the local API's replies")
struct BatutaKeyboardReplyTests {
    @Test("status names the client with the keyboard, by the name the owner gave it")
    func focusOnClient() async {
        let wire = Wire(reply: statusLinux)
        #expect(await BatutaKeyboard(exchange: wire.exchange).status() == .client(linux))
        #expect(wire.verbs == ["status"])
    }

    @Test("the focus on the first computer, the Mac, or on none, is the Mac")
    func focusOnMac() async {
        #expect(await BatutaKeyboard(exchange: Wire(reply: statusStudio).exchange).status() == .mac)
        let none = #"{"ok":true,"focus":null,"computers":[{"id":"studio","name":"Mac Studio"}]}"#
        #expect(await BatutaKeyboard(exchange: Wire(reply: none).exchange).status() == .mac)
    }

    @Test("agent access off in Batuta, and any other refusal, are told apart")
    func refusals() async {
        #expect(await BatutaKeyboard(exchange: Wire(reply: accessOff).exchange).status() == .refused(.accessOff))
        let team = #"{"ok":false,"error":"Batuta answers only apps signed by its own team."}"#
        #expect(await BatutaKeyboard(exchange: Wire(reply: team).exchange).status() == .refused(.refused))
        #expect(await BatutaKeyboard(exchange: Wire(reply: "not json").exchange).status() == .refused(.noAnswer))
    }

    @Test("no Batuta running is no Batuta; one that does not answer is said")
    func absentOrSilent() async {
        #expect(await BatutaKeyboard(exchange: Wire(throwing: LocalChannel.Failure.notRunning).exchange).status() == .absent)
        #expect(await BatutaKeyboard(exchange: Wire(throwing: LocalChannel.Failure.noReply).exchange).status()
            == .refused(.noAnswer))
    }

    @Test("something on Batuta's socket that is not Batuta gets nothing and is said, like a missing Batuta that speaks")
    func untrustedServer() async {
        let wire = Wire(throwing: AgentChannel.Failure.untrustedServer)
        #expect(await BatutaKeyboard(exchange: wire.exchange).status() == .refused(.untrustedServer))
        #expect(await BatutaKeyboard(exchange: wire.exchange).type("secreto", on: linux) == .untrustedServer)
    }

    @Test("a build that cannot check who listens never connects: no Batuta")
    func noTrustNoExchange() async {
        let keyboard = BatutaKeyboard(exchange: nil)
        #expect(await keyboard.status() == .absent)
        #expect(await keyboard.type("texto", on: linux) == .noAnswer)
    }

    @Test("type_text carries the text and the computer, so it types only where the keyboard still is")
    func typeText() async {
        let wire = Wire(reply: #"{"ok":true,"computer":"linux","bytes":5,"message":"…"}"#)
        #expect(await BatutaKeyboard(exchange: wire.exchange).type("hola\n", on: linux) == nil)
        #expect(wire.last == ["verb": "type_text", "text": "hola\n", "computer": "linux"])
    }

    @Test("a client that refuses the text is named; access turned off meanwhile is said as such")
    func typeRefused() async {
        let refused = #"{"ok":false,"error":"Workstation Linux runs on Wayland, where type_text is not offered."}"#
        #expect(await BatutaKeyboard(exchange: Wire(reply: refused).exchange).type("x", on: linux)
            == .cannotType(computer: "Workstation Linux"))
        #expect(await BatutaKeyboard(exchange: Wire(reply: accessOff).exchange).type("x", on: linux) == .accessOff)
        #expect(await BatutaKeyboard(exchange: Wire(throwing: LocalChannel.Failure.notRunning).exchange)
            .type("x", on: linux) == .noAnswer)
    }

    @Test("a wedged Batuta costs a moment, not the dictation")
    func deadline() async {
        let wedged = Wire { _ in
            try? await Task.sleep(for: .seconds(30))
            return statusLinux
        }
        let keyboard = BatutaKeyboard(exchange: wedged.exchange, deadline: .milliseconds(200))
        let start = ContinuousClock.now
        #expect(await keyboard.status() == .refused(.noAnswer))
        #expect(await keyboard.type("x", on: linux) == .noAnswer)
        #expect(start.duration(to: .now) < .seconds(2))
    }
}

/// The lines a fake connection was told to keep carrying.
private final class StandingLines: Sendable {
    private let pushed = Mutex<[[Data]]>([])

    var standing: BatutaKeyboard.Standing { { lines in self.pushed.withLock { $0.append(lines) } } }
    var pushes: Int { pushed.withLock { $0.count } }
    /// The latest standing lines, decoded.
    var last: [[String: Any]] {
        (pushed.withLock { $0.last } ?? []).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

private let optionShiftM = RemoteChord(keyCode: 46, modifiers: [.option, .shift])

/// Shared-control S6 R6: the selection on the computer with the keyboard, the shortcuts Batuta
/// keeps on the Mac, and the hold on the keys while a window of Quill needs them.
@Suite("Batuta keyboard: selection, shortcuts and hold")
struct BatutaKeyboardR6Tests {
    @Test("get_selection returns the text the computer with the keyboard has selected")
    func selection() async {
        let wire = Wire(reply: #"{"ok":true,"computer":"linux","text":"a sentence\nover two lines"}"#)
        #expect(await BatutaKeyboard(exchange: wire.exchange).selection(on: linux) == .text("a sentence\nover two lines"))
        #expect(wire.last == ["verb": "get_selection"])
    }

    @Test("a selection read on another computer than the one asked about means the keyboard moved")
    func selectionFromAnotherComputer() async {
        let wire = Wire(reply: #"{"ok":true,"computer":"air","text":"another"}"#)
        #expect(await BatutaKeyboard(exchange: wire.exchange).selection(on: linux)
            == .refused(.focusMoved(computer: "Workstation Linux")))
    }

    @Test("a client that cannot read its selection, an older Batuta, access off, no answer: each told apart")
    func selectionRefused() async {
        let wayland = #"{"ok":false,"error":"Workstation Linux runs on Wayland without data-control."}"#
        #expect(await BatutaKeyboard(exchange: Wire(reply: wayland).exchange).selection(on: linux) == .unreadable)
        let older = #"{"ok":false,"error":"\"get_selection\" is not a verb of Batuta's local API."}"#
        #expect(await BatutaKeyboard(exchange: Wire(reply: older).exchange).selection(on: linux) == .unreadable)
        #expect(await BatutaKeyboard(exchange: Wire(reply: accessOff).exchange).selection(on: linux) == .refused(.accessOff))
        #expect(await BatutaKeyboard(exchange: Wire(throwing: LocalChannel.Failure.noReply).exchange).selection(on: linux)
            == .refused(.noAnswer))
        #expect(await BatutaKeyboard(exchange: Wire(throwing: LocalChannel.Failure.notRunning).exchange).selection(on: linux)
            == .refused(.noAnswer))
        #expect(await BatutaKeyboard(exchange: Wire(throwing: AgentChannel.Failure.untrustedServer).exchange)
            .selection(on: linux) == .refused(.untrustedServer))
    }

    @Test("the shortcuts go to Batuta as reserve_hotkeys with macOS key codes and named modifiers")
    func reserveLine() throws {
        let lines = StandingLines()
        let keyboard = BatutaKeyboard(exchange: Wire(reply: "{}").exchange, standing: lines.standing)
        keyboard.reserve([optionShiftM, RemoteChord(keyCode: 15, modifiers: [.control, .option, .command])])
        let reserve = try #require(lines.last.first)
        #expect(reserve["verb"] as? String == "reserve_hotkeys")
        let chords = try #require(reserve["chords"] as? [[String: Any]])
        #expect(chords.map { $0["keyCode"] as? Int } == [46, 15])
        #expect(chords.map { $0["modifiers"] as? [String] } == [["option", "shift"], ["command", "option", "control"]])
    }

    @Test("the same shortcuts again send nothing; a change, an empty set or a hold does, the shortcuts first")
    func standingChanges() throws {
        let lines = StandingLines()
        let keyboard = BatutaKeyboard(exchange: Wire(reply: "{}").exchange, standing: lines.standing)
        keyboard.reserve([optionShiftM])
        keyboard.reserve([optionShiftM])
        #expect(lines.pushes == 1)
        keyboard.holdKeyboard(true)
        #expect(lines.last.map { $0["verb"] as? String } == ["reserve_hotkeys", "hold_keyboard"])
        #expect(lines.last.last?["hold"] as? Bool == true)
        keyboard.holdKeyboard(true)
        #expect(lines.pushes == 2)
        keyboard.holdKeyboard(false)
        #expect(lines.last.last?["hold"] as? Bool == false)
        keyboard.reserve([])
        #expect((lines.last.first?["chords"] as? [Any])?.isEmpty == true)
        #expect(lines.pushes == 4)
    }

    @Test("a build that cannot check who listens keeps its shortcuts and its hold to itself")
    func noTrustNoStanding() {
        let keyboard = BatutaKeyboard(exchange: nil)
        keyboard.reserve([optionShiftM])
        keyboard.holdKeyboard(true)
        #expect(keyboard.reservation == .none)
    }
}

/// What became of Quill's shortcuts, as the connection reports it.
@Suite("Batuta keyboard: the reservation")
struct ReservationTests {
    private let reserveLine = BatutaKeyboard.line(["verb": "reserve_hotkeys", "chords": [] as [Any]])
    private let holdLine = BatutaKeyboard.line(["verb": "hold_keyboard", "hold": true])

    private func shortcuts() -> Shortcuts {
        let shortcuts = Shortcuts()
        _ = shortcuts.set(chords: [optionShiftM])
        return shortcuts
    }

    @Test("Batuta's yes to the shortcuts makes them reserved; its refusal is kept with the reason")
    func replies() {
        let shortcuts = shortcuts()
        shortcuts.heard(.standingReply(line: reserveLine, reply: Data(#"{"ok":true,"reserved":1}"#.utf8)))
        #expect(shortcuts.reservation == .reserved)
        shortcuts.heard(.standingReply(line: reserveLine, reply: Data(accessOff.utf8)))
        #expect(shortcuts.reservation == .refused(.accessOff))
        let team = #"{"ok":false,"error":"Batuta answers only apps signed by its own team."}"#
        shortcuts.heard(.standingReply(line: reserveLine, reply: Data(team.utf8)))
        #expect(shortcuts.reservation == .refused(.refused))
        shortcuts.heard(.standingReply(line: holdLine, reply: Data(#"{"ok":true}"#.utf8)))
        #expect(shortcuts.reservation == .refused(.refused), "the hold's reply says nothing about the shortcuts")
    }

    @Test("Batuta not running reserves nothing; an impostor is said; a refusal outlives the connection it closed")
    func down() {
        let shortcuts = shortcuts()
        shortcuts.heard(.standingReply(line: reserveLine, reply: Data(#"{"ok":true,"reserved":1}"#.utf8)))
        shortcuts.heard(.down(failure: LocalChannel.Failure.noReply))
        #expect(shortcuts.reservation == .none)
        shortcuts.heard(.down(failure: AgentChannel.Failure.untrustedServer))
        #expect(shortcuts.reservation == .refused(.untrustedServer))
        shortcuts.heard(.down(failure: LocalChannel.Failure.notRunning))
        #expect(shortcuts.reservation == .none)
        shortcuts.heard(.standingReply(line: reserveLine, reply: Data(accessOff.utf8)))
        shortcuts.heard(.down(failure: LocalChannel.Failure.noReply))
        #expect(shortcuts.reservation == .refused(.accessOff))
    }

    @Test("with no shortcut to keep there is nothing to say")
    func nothingToKeep() {
        let shortcuts = Shortcuts()
        shortcuts.heard(.down(failure: AgentChannel.Failure.untrustedServer))
        #expect(shortcuts.reservation == .none)
        _ = shortcuts.set(chords: [])
        shortcuts.heard(.standingReply(line: reserveLine, reply: Data(accessOff.utf8)))
        #expect(shortcuts.reservation == .none)
    }
}

@Suite("Batuta keyboard: who it trusts")
struct BatutaKeyboardTrustTests {
    @Test("a signed Quill expects its own user and its own team on Batuta's socket")
    func signed() {
        #expect(BatutaKeyboard.trust(ownTeam: "Q4VZ9ZK2TS", trustSameUser: false, uid: 501)
            == AgentChannel.ServerTrust(uid: 501, team: "Q4VZ9ZK2TS"))
        #expect(BatutaKeyboard.trust(ownTeam: "Q4VZ9ZK2TS", trustSameUser: true, uid: 501)
            == AgentChannel.ServerTrust(uid: 501, team: "Q4VZ9ZK2TS"), "the debug switch never loosens a team")
    }

    @Test("an ad hoc Quill sends nothing to Batuta unless the debug switch says to trust the user")
    func adHoc() {
        #expect(BatutaKeyboard.trust(ownTeam: nil, trustSameUser: false, uid: 501) == nil)
        #expect(BatutaKeyboard.trust(ownTeam: nil, trustSameUser: true, uid: 501)
            == AgentChannel.ServerTrust(uid: 501, team: nil))
    }

    @Test("the socket is Batuta's local-api.sock in its data directory")
    func socketPath() {
        #expect(BatutaKeyboard.dataDirectory.path.hasSuffix("/Library/Application Support/dev.rrios.batuta"))
        let directory = URL(fileURLWithPath: "/tmp/b", isDirectory: true)
        #expect(BatutaKeyboard.socketPath(dataDirectory: directory) == LocalChannel.path(named: "local-api", in: directory))
        #expect(BatutaKeyboard.socketPath(dataDirectory: directory) == "/tmp/b/local-api.sock")
    }
}

// MARK: - The live wire, against a listener on a real socket

/// A short directory for a socket (`sun_path` holds 104 bytes).
private func makeSocketDirectory() -> URL {
    let name = "rt-" + UUID().uuidString.prefix(8).lowercased()
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A stand-in Batuta: a bare socket of this user, signed by no team, that records what its
/// first connection sent and answers one line.
private final class StandInBatuta: @unchecked Sendable {
    let path: String
    private let descriptor: Int32
    private final class Received: Sendable {
        let bytes = Mutex<Data>(Data())
    }

    private let received = Received()
    private let done = DispatchSemaphore(value: 0)

    init(path: String, reply: String) throws {
        self.path = path
        unlink(path)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw LocalChannel.Failure.io(errno)
        }
        let listening = descriptor
        let answer = Data((reply + "\n").utf8)
        let received = self.received
        let done = self.done
        let thread = Thread {
            defer { done.signal() }
            let client = accept(listening, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { break }
                received.bytes.withLock { $0.append(contentsOf: buffer[0..<count]) }
                if buffer[0..<count].contains(0x0A) { break }
            }
            guard received.bytes.withLock({ !$0.isEmpty }) else { return }
            _ = answer.withUnsafeBytes { write(client, $0.baseAddress, answer.count) }
        }
        thread.start()
    }

    /// What the first connection sent, once it is over (or after two seconds).
    func bytes() async -> Data {
        let done = self.done
        await Task.detached { Self.waitBriefly(done) }.value
        return received.bytes.withLock { $0 }
    }

    private static func waitBriefly(_ semaphore: DispatchSemaphore) {
        _ = semaphore.wait(timeout: .now() + 2)
    }

    func stop() {
        close(descriptor)
        unlink(path)
    }
}

@Suite("Batuta keyboard: the live wire", .serialized)
struct BatutaKeyboardWireTests {
    @Test("a trusted Batuta is asked for the status over its socket, one JSON line")
    func statusOverTheSocket() async throws {
        let directory = makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let batuta = try StandInBatuta(path: BatutaKeyboard.socketPath(dataDirectory: directory), reply: statusLinux)
        defer { batuta.stop() }
        let keyboard = BatutaKeyboard.live(socketPath: batuta.path, trust: AgentChannel.ServerTrust(uid: getuid(), team: nil))

        #expect(await keyboard.status() == .client(linux))
        let sent = try #require(String(data: await batuta.bytes(), encoding: .utf8))
        #expect(sent.hasSuffix("\n"))
        #expect(sent.contains(#""verb":"status""#))
    }

    @Test("a listener not signed by Quill's team reads nothing of the dictation", arguments: [
        AgentChannel.ServerTrust(uid: getuid(), team: "TESTTEAM00"),
        AgentChannel.ServerTrust(uid: getuid() &+ 1, team: nil),
    ])
    func impostorReadsNothing(_ trust: AgentChannel.ServerTrust) async throws {
        let directory = makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let impostor = try StandInBatuta(path: BatutaKeyboard.socketPath(dataDirectory: directory), reply: statusLinux)
        defer { impostor.stop() }
        let keyboard = BatutaKeyboard.live(socketPath: impostor.path, trust: trust)

        #expect(await keyboard.type("my password is hunter2", on: linux) == .untrustedServer)
        #expect(await keyboard.status() == .refused(.untrustedServer))
        #expect(await impostor.bytes().isEmpty)
    }

    @Test("no socket is no Batuta")
    func noSocket() async {
        let directory = makeSocketDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyboard = BatutaKeyboard.live(socketPath: BatutaKeyboard.socketPath(dataDirectory: directory),
                                           trust: AgentChannel.ServerTrust(uid: getuid(), team: nil))
        #expect(await keyboard.status() == .absent)
    }
}
