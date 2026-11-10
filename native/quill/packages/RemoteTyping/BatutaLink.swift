import AgentHost
import Darwin
import Foundation
import MCPKit
import Synchronization

/// A connection that carries one line at a time each way (Batuta's local API: one JSON object
/// per line). The live one is a Unix socket (`SocketLine`); tests use one in memory.
public protocol LineChannel: AnyObject, Sendable {
    /// Writes `line` and its newline; false when the connection is gone or the write stalled.
    func write(_ line: Data) -> Bool
    /// The next line, without its newline; nil once the connection is over. Blocks.
    func readLine() -> Data?
    /// Ends the connection: a blocked `readLine` returns nil.
    func shutdown()
}

/// The one connection Quill keeps open to Batuta's local API (shared-control S6 R6).
///
/// Batuta keeps an app's reserved shortcuts and its hold on the keyboard only while that
/// app's connection is open, so the connection outlives any request: it opens on the first
/// need (or at `start`), and, once started, comes back on its own after Batuta quits,
/// restarts or turns Quill away — at once when `nudge`d, else after a delay that doubles up
/// to `Timing.longestRetry`, so a Mac without Batuta costs one failed `connect` now and then.
///
/// The *standing* lines (the reserved shortcuts, the hold) are what the connection must
/// carry: they are written again on every new connection, every time they change, and every
/// `Timing.refresh` (Batuta lets a hold lapse after 60 s). Each write sends the lines as they
/// are when it runs, so the last change always wins, whatever order the changes came in.
///
/// Requests wait for their reply in order (Batuta answers in order). One that waits past
/// `Timing.deadline` fails, and the connection is closed and opened again, so a late reply
/// can never be read as the next request's.
///
/// Nothing here runs on the caller's thread but a lock held for a few assignments: dialing
/// and writing run on a private serial queue, reading on a thread of each connection's own.
/// The server check is the dial's (`AgentChannel.open`): no byte is written before it passes.
public final class BatutaLink: Sendable {
    /// Opens a connection whose server has been checked; throws `LocalChannel.Failure` or
    /// `AgentChannel.Failure` as `AgentChannel.open` does.
    public typealias Dial = @Sendable () throws -> any LineChannel

    public struct Timing: Sendable {
        /// The delay before the first new attempt after a failed one.
        public var firstRetry: Duration
        /// The longest delay between attempts while Batuta is away.
        public var longestRetry: Duration
        /// How often the standing lines are written again on an open connection.
        public var refresh: Duration
        /// How long a request may wait for its reply, connecting included.
        public var deadline: Duration

        public init(firstRetry: Duration = .seconds(1), longestRetry: Duration = .seconds(30),
                    refresh: Duration = .seconds(20), deadline: Duration = .seconds(1)) {
            self.firstRetry = firstRetry
            self.longestRetry = longestRetry
            self.refresh = refresh
            self.deadline = deadline
        }
    }

    /// What the link tells its owner.
    public enum Event: Sendable {
        /// The reply to a standing line (`line`, as written).
        case standingReply(line: Data, reply: Data)
        /// There is no connection: `failure` ended it or kept it from opening.
        case down(failure: any Error)
    }

    private struct Pending: Sendable {
        let resume: @Sendable (Result<Data, any Error>) -> Void
    }

    private struct State: Sendable {
        var started = false
        var stopped = false
        var channel: (any LineChannel)?
        /// Counts connections; whatever belongs to an older one is ignored.
        var generation = 0
        var pending: [Pending] = []
        var standing: [Data] = []
        /// Why the last attempt to open a connection failed.
        var lastFailure: any Error = LocalChannel.Failure.notRunning
        var retryDelay: Duration
        /// Only the latest scheduled attempt runs.
        var retryToken = 0
        /// This connection has answered a line with `"ok": true`.
        var answered = false
        /// The last `"ok": false` line of this connection. Batuta turns a connection down with
        /// one such line and closes it: requests still waiting then get it as their reply.
        var refusal: Data?
    }

    private let dial: Dial
    private let timing: Timing
    private let onEvent: @Sendable (Event) -> Void
    private let state: Mutex<State>
    private let queue = DispatchQueue(label: "dev.rrios.quill.batuta-link")

    public init(dial: @escaping Dial, timing: Timing = Timing(), onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.dial = dial
        self.timing = timing
        self.onEvent = onEvent
        state = Mutex(State(retryDelay: timing.firstRetry))
    }

    // MARK: Life

    /// Opens the connection now and keeps it open from here on.
    public func start() {
        state.withLock { $0.started = true }
        queue.async { _ = self.connection() }
    }

    /// Batuta has just launched: try now, and start the delays over.
    public func nudge() {
        state.withLock { state in
            state.retryDelay = timing.firstRetry
            state.retryToken += 1
        }
        queue.async { _ = self.connection() }
    }

    /// Closes the connection for good (Batuta then drops what it kept for it).
    public func stop() {
        let generation = state.withLock { state in
            state.stopped = true
            state.started = false
            return state.generation
        }
        drop(generation, because: LocalChannel.Failure.notRunning)
    }

    /// Whether a connection is open now.
    public var isConnected: Bool { state.withLock { $0.channel != nil } }

    // MARK: Lines

    /// Replaces the standing lines and writes them now (opening the connection if needed).
    public func setStanding(_ lines: [Data]) {
        state.withLock { $0.standing = lines }
        queue.async {
            // A connection opened just now has written them already.
            guard let (channel, generation, opened) = self.connection(), !opened else { return }
            self.writeStanding(on: channel, generation)
        }
    }

    /// Sends one request and returns its reply line, or Batuta's refusal of the connection.
    ///
    /// - Throws: the dial's failure when no connection opens; `LocalChannel.Failure.noReply`
    ///   when the reply does not come in time or the connection closes first;
    ///   `LocalChannel.Failure.tooLong` for a line over the API's limit.
    public func send(_ request: Data) async throws -> Data {
        guard request.count < LocalChannel.maxLine else { throw LocalChannel.Failure.tooLong }
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceResult(continuation)
            let written = WrittenOn()
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.seconds(timing.deadline)) {
                guard once.resume(.failure(LocalChannel.Failure.noReply)) else { return }
                // The reply may still come: a new connection keeps it from answering the next request.
                if let generation = written.generation { self.drop(generation, because: LocalChannel.Failure.noReply) }
            }
            queue.async {
                guard let (channel, generation, _) = self.connection() else {
                    once.resume(.failure(self.state.withLock { $0.lastFailure }))
                    return
                }
                guard self.enqueue(Pending(resume: { once.resume($0) }), generation) else {
                    once.resume(.failure(LocalChannel.Failure.noReply))
                    return
                }
                written.generation = generation
                // A failed write is left to the reader: Batuta may have written why it closed
                // (a refusal) before closing, and the reader hands that to this request. A
                // stalled Batuta that never closes is ended by the deadline above.
                _ = channel.write(request)
            }
        }
    }

    // MARK: On the queue

    /// The open connection, opening one (`opened`) when there is none. On `queue` only.
    private func connection() -> (channel: any LineChannel, generation: Int, opened: Bool)? {
        let current = state.withLock { state in (stopped: state.stopped, channel: state.channel, generation: state.generation) }
        if current.stopped { return nil }
        if let channel = current.channel { return (channel, current.generation, false) }
        let channel: any LineChannel
        do {
            channel = try dial()
        } catch {
            state.withLock { $0.lastFailure = error }
            onEvent(.down(failure: error))
            scheduleRetry()
            return nil
        }
        let generation = state.withLock { state in
            state.generation += 1
            state.channel = channel
            state.answered = false
            state.refusal = nil
            return state.generation
        }
        Thread { self.read(channel, generation) }.start()
        writeStanding(on: channel, generation)
        scheduleRefresh(generation)
        return (channel, generation, true)
    }

    /// Writes the standing lines as they are now. On `queue` only.
    private func writeStanding(on channel: any LineChannel, _ generation: Int) {
        let lines = state.withLock { $0.standing }
        for line in lines {
            let onEvent = self.onEvent
            let pending = Pending { result in
                if case .success(let reply) = result { onEvent(.standingReply(line: line, reply: reply)) }
            }
            guard enqueue(pending, generation) else { return }
            // As for a request, a failed write is the reader's to notice.
            guard channel.write(line) else { return }
        }
    }

    /// Adds a reply to wait for, if `generation` is still the open connection.
    private func enqueue(_ pending: Pending, _ generation: Int) -> Bool {
        state.withLock { state in
            guard state.generation == generation, state.channel != nil else { return false }
            state.pending.append(pending)
            return true
        }
    }

    private func scheduleRefresh(_ generation: Int) {
        queue.asyncAfter(deadline: .now() + Self.seconds(timing.refresh)) {
            let open = self.state.withLock { state in
                state.generation == generation ? state.channel : nil
            }
            guard let open else { return }
            self.writeStanding(on: open, generation)
            self.scheduleRefresh(generation)
        }
    }

    private func scheduleRetry() {
        let plan: (token: Int, delay: Duration)? = state.withLock { state in
            guard state.started, !state.stopped, state.channel == nil else { return nil }
            state.retryToken += 1
            let delay = state.retryDelay
            state.retryDelay = min(delay * 2, timing.longestRetry)
            return (state.retryToken, delay)
        }
        guard let plan else { return }
        queue.asyncAfter(deadline: .now() + Self.seconds(plan.delay)) {
            guard self.state.withLock({ $0.retryToken == plan.token && $0.channel == nil }) else { return }
            _ = self.connection()
        }
    }

    // MARK: Anywhere

    /// Each connection's reader: replies go to the requests in the order they were written.
    private func read(_ channel: any LineChannel, _ generation: Int) {
        while let line = channel.readLine() {
            let ok = Self.ok(line)
            let waiting: Pending? = state.withLock { state in
                guard state.generation == generation else { return nil }
                if ok == true {
                    state.answered = true
                    state.retryDelay = timing.firstRetry
                } else if ok == false {
                    state.refusal = line
                }
                return state.pending.isEmpty ? nil : state.pending.removeFirst()
            }
            waiting?.resume(.success(line))
        }
        drop(generation, because: LocalChannel.Failure.noReply)
    }

    /// Closes connection `generation` if it is still the open one; the requests waiting on it
    /// get Batuta's refusal when it turned the connection down, else `failure`.
    private func drop(_ generation: Int, because failure: any Error) {
        let taken: (channel: any LineChannel, pending: [Pending], refusal: Data?)? = state.withLock { state in
            guard state.generation == generation, let channel = state.channel else { return nil }
            state.channel = nil
            let pending = state.pending
            state.pending = []
            return (channel, pending, state.answered ? nil : state.refusal)
        }
        guard let taken else { return }
        taken.channel.shutdown()
        for waiting in taken.pending {
            waiting.resume(taken.refusal.map { .success($0) } ?? .failure(failure))
        }
        onEvent(.down(failure: failure))
        queue.async { self.scheduleRetry() }
    }

    /// The line's `ok`, if it is a JSON object that has one.
    private static func ok(_ line: Data) -> Bool? {
        (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["ok"] as? Bool
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// A throwing continuation resumed by whichever side comes first.
private final class OnceResult<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = Mutex(continuation)
    }

    /// Whether this call was the one that resumed it.
    @discardableResult
    func resume(_ result: Result<T, any Error>) -> Bool {
        let pending = continuation.withLock { pending -> CheckedContinuation<T, any Error>? in
            defer { pending = nil }
            return pending
        }
        pending?.resume(with: result)
        return pending != nil
    }
}

/// The connection a request was written on, for its deadline to close.
private final class WrittenOn: Sendable {
    private let value = Mutex<Int?>(nil)

    var generation: Int? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

/// `LineChannel` over a connected Unix socket descriptor, which it owns and closes.
public final class SocketLine: LineChannel {
    private let descriptor: Int32
    /// Bytes read past the last line returned. Only the connection's reader touches it.
    private let buffer = Mutex(Data())

    /// - Parameter sendTimeout: how long a write may wait for Batuta to read.
    public init(descriptor: Int32, sendTimeout: Duration = .seconds(1)) {
        self.descriptor = descriptor
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: Int(sendTimeout.components.seconds),
                              tv_usec: Int32(sendTimeout.components.attoseconds / 1_000_000_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close(descriptor) }

    public func write(_ line: Data) -> Bool {
        (line + Data([0x0A])).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    public func readLine() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let line: Data? = buffer.withLock { buffer in
                guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                return line
            }
            if let line { return line }
            // A line longer than the API allows is not Batuta speaking: the connection is over.
            guard buffer.withLock({ $0.count }) < LocalChannel.maxLine else { return nil }
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.withLock { $0.append(contentsOf: chunk[0..<count]) }
        }
    }

    public func shutdown() {
        Darwin.shutdown(descriptor, SHUT_RDWR)
    }
}
