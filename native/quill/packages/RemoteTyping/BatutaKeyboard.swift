import AgentHost
import Foundation
import MCPKit
import Synchronization

/// `RemoteKeyboard` over Batuta's local API (`native/batuta/docs/local-api.md`): verbs
/// `status`, `type_text`, `get_selection`, `reserve_hotkeys` and `hold_keyboard`, one JSON
/// object per line, on `<Batuta's data directory>/local-api.sock`.
///
/// No dependency on Batuta's code: Quill builds and ships without it. The check of who
/// listens is AgentHost's (`AgentChannel.open`): before a byte is written, the listening
/// process must run as this user and carry this build's Team ID, so a process that bound the
/// socket in Batuta's place never reads the text. The live keyboard keeps one connection open
/// (`BatutaLink`), because Batuta keeps Quill's shortcuts and its hold on the keyboard only
/// while it is; each request is bounded by `deadline`, so a wedged Batuta costs the text a
/// moment, never the text itself.
public struct BatutaKeyboard: RemoteKeyboard {
    /// One request out, one reply line back (without its newline). Throws AgentHost's and
    /// MCPKit's failures.
    public typealias Exchange = @Sendable (Data) async throws -> Data
    /// Hands over the lines the connection must keep carrying (`BatutaLink.setStanding`).
    public typealias Standing = @Sendable ([Data]) -> Void

    /// Batuta's bundle identifier, which names its data directory.
    public static let bundleIdentifier = "dev.rrios.batuta"
    /// The socket's name inside Batuta's data directory.
    public static let socketName = "local-api"
    /// The start of Batuta's sentence while its "Tus apps" switch is off (`BatutaTools`).
    static let accessOffPrefix = "Agent access is off"

    private let exchange: Exchange?
    private let standing: Standing?
    private let link: BatutaLink?
    private let shortcuts: Shortcuts
    private let deadline: Duration

    /// - Parameters:
    ///   - exchange: the wire; nil when this build cannot check who listens, which reads as
    ///     no Batuta at all (nothing is sent).
    ///   - standing: where the reserved shortcuts and the hold go; nil keeps them unsent.
    ///   - deadline: how long one request may take, connecting included.
    public init(exchange: Exchange?, standing: Standing? = nil, deadline: Duration = .seconds(1)) {
        self.init(exchange: exchange, standing: standing, link: nil, shortcuts: Shortcuts(), deadline: deadline)
    }

    private init(exchange: Exchange?, standing: Standing?, link: BatutaLink?, shortcuts: Shortcuts, deadline: Duration) {
        self.exchange = exchange
        self.standing = standing
        self.link = link
        self.shortcuts = shortcuts
        self.deadline = deadline
    }

    /// Batuta's data directory: Application Support, under its bundle identifier.
    public static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// The socket inside `dataDirectory`, shortened as Batuta shortens it (`LocalChannel.path`).
    public static func socketPath(dataDirectory: URL) -> String {
        LocalChannel.path(named: socketName, in: dataDirectory)
    }

    /// Who may answer on Batuta's socket: this user and this build's team. A build with no
    /// team (ad hoc, for development) cannot tell Batuta from any other process of the user,
    /// so it trusts nobody unless `trustSameUser` — a debug-only switch — says so. A team is
    /// never loosened by the switch.
    public static func trust(ownTeam: String?, trustSameUser: Bool, uid: uid_t = getuid()) -> AgentChannel.ServerTrust? {
        if let ownTeam { return AgentChannel.ServerTrust(uid: uid, team: ownTeam) }
        return trustSameUser ? AgentChannel.ServerTrust(uid: uid, team: nil) : nil
    }

    /// The live keyboard on the socket at `socketPath`, over one kept connection; with no
    /// `trust`, it never connects. Call `start` to keep the connection open from launch.
    public static func live(socketPath: String, trust: AgentChannel.ServerTrust?,
                            deadline: Duration = .seconds(1)) -> BatutaKeyboard {
        guard let trust else { return BatutaKeyboard(exchange: nil, deadline: deadline) }
        return linked(timing: BatutaLink.Timing(deadline: deadline)) {
            SocketLine(descriptor: try AgentChannel.open(socketPath, trust: trust))
        }
    }

    /// A keyboard over a `BatutaLink` that dials with `dial` (the live socket, or a test's).
    public static func linked(timing: BatutaLink.Timing = BatutaLink.Timing(),
                              dial: @escaping BatutaLink.Dial) -> BatutaKeyboard {
        let shortcuts = Shortcuts()
        let link = BatutaLink(dial: dial, timing: timing) { shortcuts.heard($0) }
        return BatutaKeyboard(exchange: { try await link.send($0) }, standing: { link.setStanding($0) },
                              link: link, shortcuts: shortcuts, deadline: timing.deadline)
    }

    // MARK: The connection

    /// Opens the connection and keeps it open: Batuta's restarts are followed, and the
    /// reserved shortcuts come back with it.
    public func start() { link?.start() }

    /// Batuta has just launched: connect now rather than at the next attempt.
    public func nudge() { link?.nudge() }

    /// Closes the connection; Batuta drops Quill's shortcuts and hold with it.
    public func stop() { link?.stop() }

    // MARK: Verbs

    public func status() async -> RemoteStatus {
        switch await ask(Self.line(["verb": "status"])) {
        case .absent: return .absent
        case .refused(let refusal): return .refused(refusal)
        case .reply(let reply):
            guard reply.ok else { return .refused(Self.refusal(reply.error, otherwise: .refused)) }
            // The Mac is listed first (local-api.md); a focus on it, or on nobody, is the Mac.
            guard let focus = reply.focus, focus != reply.computers.first?.id else { return .mac }
            let name = reply.computers.first { $0.id == focus }?.name
            return .client(RemoteComputer(id: focus, name: name ?? focus))
        }
    }

    public func type(_ text: String, on computer: RemoteComputer) async -> RemoteRefusal? {
        switch await ask(Self.line(["verb": "type_text", "text": text, "computer": computer.id])) {
        // Batuta quit between the status and the text: the caller keeps the text.
        case .absent: return .noAnswer
        case .refused(.noAnswer) where text.utf8.count > 64 * 1024: return .cannotType(computer: computer.name)
        case .refused(let refusal): return refusal
        case .reply(let reply):
            guard reply.ok else { return Self.refusal(reply.error, otherwise: .cannotType(computer: computer.name)) }
            return nil
        }
    }

    public func selection(on computer: RemoteComputer) async -> RemoteSelection {
        switch await ask(Self.line(["verb": "get_selection"])) {
        // Batuta quit between the status and the question.
        case .absent: return .refused(.noAnswer)
        case .refused(let refusal): return .refused(refusal)
        case .reply(let reply):
            guard reply.ok else {
                // A Batuta older than the verb, or a client that cannot read its selection.
                return reply.error?.hasPrefix(Self.accessOffPrefix) == true ? .refused(.accessOff) : .unreadable
            }
            if let from = reply.computer, from != computer.id { return .refused(.focusMoved(computer: computer.name)) }
            return .text(reply.text ?? "")
        }
    }

    public func holdKeyboard(_ hold: Bool) {
        guard shortcuts.set(hold: hold) else { return }
        standing?(shortcuts.lines)
    }

    public func reserve(_ chords: [RemoteChord]) {
        guard shortcuts.set(chords: chords) else { return }
        standing?(shortcuts.lines)
    }

    public var reservation: RemoteReservation { shortcuts.reservation }

    // MARK: The wire

    private enum Answer: Sendable {
        case absent
        case refused(RemoteRefusal)
        case reply(Reply)
    }

    /// The fields of a reply Quill reads; unknown ones are ignored, as the API asks.
    struct Reply: Sendable {
        var ok: Bool
        var error: String?
        var focus: String?
        var computers: [RemoteComputer]
        /// `get_selection`: the computer the text was read on, and the text.
        var computer: String?
        var text: String?

        init?(_ data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = object["ok"] as? Bool else { return nil }
            self.ok = ok
            error = object["error"] as? String
            focus = object["focus"] as? String
            computer = object["computer"] as? String
            text = object["text"] as? String
            computers = (object["computers"] as? [[String: Any]] ?? []).compactMap { computer in
                guard let id = computer["id"] as? String else { return nil }
                return RemoteComputer(id: id, name: computer["name"] as? String ?? id)
            }
        }
    }

    static func refusal(_ error: String?, otherwise: RemoteRefusal) -> RemoteRefusal {
        error?.hasPrefix(accessOffPrefix) == true ? .accessOff : otherwise
    }

    /// A request as one line of JSON (strings escaped, so a text with newlines stays one line).
    static func line(_ request: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? Data()
    }

    private func ask(_ data: Data) async -> Answer {
        guard let exchange, !data.isEmpty else { return .absent }
        return await Self.within(deadline, otherwise: .refused(.noAnswer)) {
            do {
                return Reply(try await exchange(data)).map(Answer.reply) ?? .refused(.noAnswer)
            } catch LocalChannel.Failure.notRunning {
                return .absent
            } catch AgentChannel.Failure.untrustedServer {
                return .refused(.untrustedServer)
            } catch {
                return .refused(.noAnswer)
            }
        }
    }

    /// `operation`'s result, or `otherwise` once `deadline` passes. The operation is not
    /// awaited past the deadline: a read blocked on a wedged socket ends on its own
    /// (`AgentChannel.send`'s receive timeout) without holding the caller.
    private static func within<T: Sendable>(_ deadline: Duration, otherwise: T,
                                            _ operation: @escaping @Sendable () async -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let once = Once(continuation)
            let timer = Task {
                try? await Task.sleep(for: deadline)
                once.resume(otherwise)
            }
            Task {
                once.resume(await operation())
                timer.cancel()
            }
        }
    }
}

/// A continuation resumed by whichever side comes first.
private final class Once<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, Never>?>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: T) {
        continuation.withLock { pending -> CheckedContinuation<T, Never>? in
            defer { pending = nil }
            return pending
        }?.resume(returning: value)
    }
}

/// What Quill asks Batuta to keep for it on the connection — its shortcuts and the hold, as
/// standing lines — and what became of the shortcuts.
final class Shortcuts: Sendable {
    private struct State {
        /// nil until Quill first says which shortcuts it has.
        var chords: [RemoteChord]?
        /// nil until a window of Quill first asks for the keys.
        var hold: Bool?
        var reservation: RemoteReservation = .none
    }

    private let state = Mutex(State())

    /// Sets the shortcuts; false when they are the ones already set.
    func set(chords: [RemoteChord]) -> Bool {
        state.withLock { state in
            guard state.chords != chords else { return false }
            state.chords = chords
            if chords.isEmpty { state.reservation = .none }
            return true
        }
    }

    /// Sets the hold; false when it is the one already set.
    func set(hold: Bool) -> Bool {
        state.withLock { state in
            guard state.hold != hold else { return false }
            state.hold = hold
            return true
        }
    }

    /// The standing lines: the shortcuts first, then the hold.
    var lines: [Data] {
        let (chords, hold) = state.withLock { ($0.chords, $0.hold) }
        var lines: [Data] = []
        if let chords {
            lines.append(BatutaKeyboard.line(["verb": "reserve_hotkeys", "chords": chords.map(Self.json)]))
        }
        if let hold { lines.append(BatutaKeyboard.line(["verb": "hold_keyboard", "hold": hold])) }
        return lines
    }

    var reservation: RemoteReservation { state.withLock { $0.reservation } }

    /// What the connection reported: the reply to the shortcuts, or that it is down.
    func heard(_ event: BatutaLink.Event) {
        switch event {
        case .standingReply(let line, let reply):
            let verb = (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["verb"] as? String
            guard verb == "reserve_hotkeys" else { return }
            let parsed = BatutaKeyboard.Reply(reply)
            state.withLock { state in
                guard state.chords?.isEmpty == false else { return state.reservation = .none }
                guard let parsed else { return state.reservation = .refused(.noAnswer) }
                state.reservation = parsed.ok
                    ? .reserved : .refused(BatutaKeyboard.refusal(parsed.error, otherwise: .refused))
            }
        case .down(let failure):
            state.withLock { state in
                if (failure as? LocalChannel.Failure) == .notRunning || state.chords?.isEmpty != false {
                    // Batuta is not running, or nothing was asked of it: there is nothing to keep.
                    state.reservation = .none
                } else if (failure as? AgentChannel.Failure) == .untrustedServer {
                    state.reservation = .refused(.untrustedServer)
                } else if case .refused = state.reservation {
                    // Batuta turned the connection down and closed it: the refusal stands.
                } else {
                    state.reservation = .none
                }
            }
        }
    }

    /// A chord as `reserve_hotkeys` takes it: the key code and the modifiers, in a fixed order.
    private static func json(_ chord: RemoteChord) -> [String: Any] {
        ["keyCode": chord.keyCode,
         "modifiers": RemoteChord.Modifier.allCases.filter(chord.modifiers.contains).map(\.rawValue)]
    }
}
