import AgentHost
import Darwin
import Foundation
import MCPKit
import Synchronization
import Testing

@testable import RemoteTyping

// MARK: - An in-memory Batuta

/// One connection to the fake Batuta: what the client wrote, and the lines it reads.
private final class MemoryLine: LineChannel {
    private struct State {
        var inbox: [Data] = []
        var over = false
        var written: [Data] = []
    }

    private let state = Mutex(State())
    private let arrived = DispatchSemaphore(value: 0)
    private let answer: @Sendable (Data) -> Data?

    init(answer: @escaping @Sendable (Data) -> Data?) { self.answer = answer }

    var written: [Data] { state.withLock { $0.written } }
    var verbs: [String] { written.compactMap { MemoryLine.object($0)["verb"] as? String } }
    var isOver: Bool { state.withLock { $0.over } }

    func write(_ line: Data) -> Bool {
        let reply = answer(line)
        let accepted = state.withLock { state -> Bool in
            guard !state.over else { return false }
            state.written.append(line)
            if let reply { state.inbox.append(reply) }
            return true
        }
        if accepted, reply != nil { arrived.signal() }
        return accepted
    }

    func readLine() -> Data? {
        while true {
            let next: Data?? = state.withLock { state in
                if !state.inbox.isEmpty { return .some(state.inbox.removeFirst()) }
                return state.over ? .some(nil) : nil
            }
            if let next { return next }
            arrived.wait()
        }
    }

    func shutdown() { hangUp() }

    /// Batuta writes a line of its own (a refusal before it closes).
    func push(_ line: String) {
        state.withLock { $0.inbox.append(Data(line.utf8)) }
        arrived.signal()
    }

    /// Batuta closes the connection (it quit, or turned the client down).
    func hangUp() {
        state.withLock { $0.over = true }
        arrived.signal()
    }

    static func object(_ line: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
    }
}

/// A fake Batuta the link dials: running or not, and how it answers each verb.
private final class FakeBatutaServer: Sendable {
    private struct State {
        var running = true
        var dials = 0
        var connections: [MemoryLine] = []
        /// The next connection is turned down with this line.
        var refuseWith: String?
        /// Requests with this verb get no answer.
        var silentVerb: String?
    }

    private let state = Mutex(State())

    var dials: Int { state.withLock { $0.dials } }
    var connections: [MemoryLine] { state.withLock { $0.connections } }
    var current: MemoryLine? { connections.last }

    func quit() {
        let open = state.withLock { state -> [MemoryLine] in
            state.running = false
            return state.connections
        }
        open.forEach { $0.hangUp() }
    }

    func launch() { state.withLock { $0.running = true } }
    func refuseNext(with line: String) { state.withLock { $0.refuseWith = line } }
    func silence(_ verb: String?) { state.withLock { $0.silentVerb = verb } }

    var dial: BatutaLink.Dial {
        {
            let refusal = try self.state.withLock { state -> String? in
                state.dials += 1
                guard state.running else { throw LocalChannel.Failure.notRunning }
                defer { state.refuseWith = nil }
                return state.refuseWith
            }
            let line = MemoryLine { request in self.answer(request) }
            self.state.withLock { $0.connections.append(line) }
            if let refusal {
                line.push(refusal)
                line.hangUp()
            }
            return line
        }
    }

    private func answer(_ request: Data) -> Data? {
        let verb = MemoryLine.object(request)["verb"] as? String
        if verb == state.withLock({ $0.silentVerb }) { return nil }
        let reply = switch verb {
        case "status": #"{"ok":true,"focus":"linux","computers":[{"id":"studio","name":"Mac Studio"},{"id":"linux","name":"Workstation Linux"}]}"#
        case "reserve_hotkeys": #"{"ok":true,"reserved":1}"#
        case "get_selection": #"{"ok":true,"computer":"linux","text":"selected"}"#
        default: #"{"ok":true}"#
        }
        return Data(reply.utf8)
    }
}

/// Waits until `condition` holds, up to `limit`.
private func eventually(within limit: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let start = ContinuousClock.now
    while start.duration(to: .now) < limit {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private let fast = BatutaLink.Timing(firstRetry: .milliseconds(20), longestRetry: .milliseconds(80),
                                     refresh: .seconds(60), deadline: .milliseconds(300))
private let status = BatutaKeyboard.line(["verb": "status"])
private let reserve = BatutaKeyboard.line(["verb": "reserve_hotkeys", "chords": [["keyCode": 46, "modifiers": ["option"]]]])

// MARK: - The kept connection

@Suite("Batuta link: one kept connection", .serialized)
struct BatutaLinkTests {
    @Test("many requests share one connection, and each reply goes to its own request")
    func oneConnection() async throws {
        let batuta = FakeBatutaServer()
        let link = BatutaLink(dial: batuta.dial, timing: fast)
        let first = try await link.send(status)
        let second = try await link.send(BatutaKeyboard.line(["verb": "get_selection"]))
        #expect(MemoryLine.object(first)["focus"] as? String == "linux")
        #expect(MemoryLine.object(second)["text"] as? String == "selected")
        #expect(batuta.dials == 1)
        #expect(batuta.current?.verbs == ["status", "get_selection"])
    }

    @Test("the standing lines open every connection, before any request")
    func standingFirst() async throws {
        let batuta = FakeBatutaServer()
        let link = BatutaLink(dial: batuta.dial, timing: fast)
        link.setStanding([reserve])
        #expect(await eventually { batuta.current?.verbs == ["reserve_hotkeys"] })
        _ = try await link.send(status)
        #expect(batuta.current?.verbs == ["reserve_hotkeys", "status"])
    }

    @Test("after Batuta restarts, a started link connects again on its own and reserves again")
    func reconnectsAndReserves() async {
        let batuta = FakeBatutaServer()
        let link = BatutaLink(dial: batuta.dial, timing: fast)
        link.setStanding([reserve])
        link.start()
        #expect(await eventually { batuta.connections.count == 1 && link.isConnected })
        batuta.quit()
        #expect(await eventually { !link.isConnected })
        batuta.launch()
        #expect(await eventually { batuta.connections.count == 2 && link.isConnected })
        #expect(await eventually { batuta.current?.verbs == ["reserve_hotkeys"] })
        link.stop()
    }

    @Test("with Batuta absent a started link waits longer and longer between attempts, never in a busy loop")
    func idleWhileAbsent() async throws {
        let batuta = FakeBatutaServer()
        batuta.quit()
        let link = BatutaLink(dial: batuta.dial, timing: fast)
        link.start()
        try await Task.sleep(for: .milliseconds(600))
        link.stop()
        // 20 + 40 + 80 + 80… ms: about nine attempts in 600 ms, not hundreds.
        #expect(batuta.dials >= 3)
        #expect(batuta.dials <= 12)
    }

    @Test("a nudge connects at once, without waiting for the next attempt")
    func nudge() async throws {
        let batuta = FakeBatutaServer()
        batuta.quit()
        let slow = BatutaLink.Timing(firstRetry: .seconds(30), longestRetry: .seconds(30), refresh: .seconds(60),
                                     deadline: .milliseconds(300))
        let link = BatutaLink(dial: batuta.dial, timing: slow)
        link.start()
        #expect(await eventually { batuta.dials == 1 })
        batuta.launch()
        link.nudge()
        #expect(await eventually(within: .seconds(1)) { link.isConnected })
        link.stop()
    }

    @Test("an unstarted link connects on demand and stays quiet otherwise")
    func onDemand() async throws {
        let batuta = FakeBatutaServer()
        batuta.quit()
        let link = BatutaLink(dial: batuta.dial, timing: fast)
        await #expect(throws: LocalChannel.Failure.notRunning) { try await link.send(status) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(batuta.dials == 1)
    }

    @Test("a reply that does not come in time fails its request, and the next one gets its own reply on a new connection")
    func deadlineReplacesTheConnection() async throws {
        let batuta = FakeBatutaServer()
        let link = BatutaLink(dial: batuta.dial, timing: fast)
        batuta.silence("status")
        let start = ContinuousClock.now
        await #expect(throws: LocalChannel.Failure.noReply) { try await link.send(status) }
        #expect(start.duration(to: .now) < .seconds(2))
        batuta.silence(nil)
        let reply = try await link.send(BatutaKeyboard.line(["verb": "get_selection"]))
        #expect(MemoryLine.object(reply)["text"] as? String == "selected")
        #expect(batuta.connections.count == 2)
        #expect(batuta.connections.first?.isOver == true)
    }

    @Test("a connection Batuta turns down hands its refusal to the requests waiting on it")
    func refusalReachesTheRequest() async throws {
        let batuta = FakeBatutaServer()
        let refusal = #"{"ok":false,"error":"Batuta answers only apps signed by its own team."}"#
        batuta.refuseNext(with: refusal)
        let link = BatutaLink(dial: batuta.dial, timing: fast)
        let reply = try await link.send(status)
        #expect(MemoryLine.object(reply)["ok"] as? Bool == false)
        let keyboard = BatutaKeyboard.linked(timing: fast, dial: batuta.dial)
        batuta.refuseNext(with: refusal)
        #expect(await keyboard.status() == .refused(.refused))
    }

    @Test("the reserved shortcuts' fate reaches the keyboard: reserved, then nothing once Batuta is gone")
    func reservationFollowsTheConnection() async {
        let batuta = FakeBatutaServer()
        let keyboard = BatutaKeyboard.linked(timing: fast, dial: batuta.dial)
        keyboard.reserve([RemoteChord(keyCode: 46, modifiers: [.option, .shift])])
        #expect(await eventually { keyboard.reservation == .reserved })
        batuta.quit()
        #expect(await eventually { keyboard.reservation == .none })
    }

    @Test("the standing lines are written again while the connection lasts, so a hold never lapses")
    func refresh() async {
        let batuta = FakeBatutaServer()
        let timing = BatutaLink.Timing(firstRetry: .milliseconds(20), longestRetry: .milliseconds(80),
                                       refresh: .milliseconds(50), deadline: .milliseconds(300))
        let keyboard = BatutaKeyboard.linked(timing: timing, dial: batuta.dial)
        keyboard.holdKeyboard(true)
        #expect(await eventually { (batuta.current?.verbs.count ?? 0) >= 3 })
        #expect(Set(batuta.current?.verbs ?? []) == ["hold_keyboard"])
        keyboard.stop()
    }

    @Test("the last hold asked for is the one Batuta keeps, however fast they come")
    func lastHoldWins() async {
        let batuta = FakeBatutaServer()
        let keyboard = BatutaKeyboard.linked(timing: fast, dial: batuta.dial)
        for _ in 0..<20 {
            keyboard.holdKeyboard(true)
            keyboard.holdKeyboard(false)
        }
        keyboard.holdKeyboard(true)
        #expect(await eventually {
            batuta.current.map { MemoryLine.object($0.written.last ?? Data())["hold"] as? Bool } == true
        })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(batuta.current.map { MemoryLine.object($0.written.last ?? Data())["hold"] as? Bool } == true)
    }

    @Test("starting, nudging and changing the standing lines never wait for a slow dial")
    func neverBlocksTheCaller() {
        let link = BatutaLink(dial: {
            Thread.sleep(forTimeInterval: 0.5)
            throw LocalChannel.Failure.notRunning
        }, timing: fast)
        let start = ContinuousClock.now
        link.start()
        link.nudge()
        link.setStanding([reserve])
        link.stop()
        #expect(start.duration(to: .now) < .milliseconds(100))
    }
}

// MARK: - Over a real socket

/// A stand-in Batuta on a real socket that keeps each connection and answers every line.
private final class KeptSocketServer: Sendable {
    let path: String
    private let descriptor: Int32
    private final class Lines: Sendable {
        let received = Mutex<[String]>([])
    }

    private let lines = Lines()

    init(path: String) throws {
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
        let lines = self.lines
        Thread {
            let client = accept(listening, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            let line = SocketLine(descriptor: dup(client))
            while let request = line.readLine() {
                lines.received.withLock { $0.append(String(decoding: request, as: UTF8.self)) }
                let verb = MemoryLine.object(request)["verb"] as? String
                let reply = verb == "status"
                    ? #"{"ok":true,"focus":"linux","computers":[{"id":"studio","name":"Mac Studio"},{"id":"linux","name":"Workstation Linux"}]}"#
                    : #"{"ok":true}"#
                guard line.write(Data(reply.utf8)) else { return }
            }
        }.start()
    }

    var received: [String] { lines.received.withLock { $0 } }

    func stop() {
        close(descriptor)
        unlink(path)
    }
}

@Suite("Batuta link: over a real socket", .serialized)
struct BatutaLinkSocketTests {
    @Test("the live keyboard keeps one checked connection: the shortcuts, then every request, on it")
    func liveKeeps() async throws {
        let name = "bl-" + UUID().uuidString.prefix(8).lowercased()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try KeptSocketServer(path: BatutaKeyboard.socketPath(dataDirectory: directory))
        defer { server.stop() }
        let keyboard = BatutaKeyboard.live(socketPath: server.path, trust: AgentChannel.ServerTrust(uid: getuid(), team: nil))
        defer { keyboard.stop() }

        keyboard.reserve([RemoteChord(keyCode: 46, modifiers: [.option, .shift])])
        #expect(await keyboard.status() == .client(RemoteComputer(id: "linux", name: "Workstation Linux")))
        #expect(await keyboard.status() == .client(RemoteComputer(id: "linux", name: "Workstation Linux")))
        #expect(await eventually { server.received.count == 3 })
        #expect(server.received.first?.contains(#""verb":"reserve_hotkeys""#) == true)
        #expect(server.received.dropFirst().allSatisfy { $0.contains(#""verb":"status""#) })
        #expect(await eventually { keyboard.reservation == .reserved })
    }
}
