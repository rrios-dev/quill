import Foundation

/// A copy of the pasteboard taken so it can be put back after a paste (ARCHITECTURE §3.4).
public struct PasteboardSnapshot: Equatable, Sendable {
    public var items: [PasteboardItemData]
    /// The change count when the snapshot started.
    public var changeCount: Int
    /// Only a complete snapshot is ever restored: restoring part of a clipboard would
    /// silently drop the rest.
    public var incompleteReason: IncompleteReason?

    public var isComplete: Bool { incompleteReason == nil }

    public enum IncompleteReason: String, Codable, Sendable {
        /// The reads did not finish within the deadline; one may still be running.
        case timedOut
        /// Over the size cap.
        case tooLarge
        /// A type was skipped (a file promise, or data that could not be read).
        case skippedType
        /// The pasteboard changed while it was being read.
        case changedWhileReading
        /// The access policy does not allow reading (only Always Allow does).
        case readingNotAllowed
    }

    public static let defaultSizeCap = 10 * 1024 * 1024
}

/// A snapshot read that may still be running after its deadline.
///
/// `data(forType:)` blocks and cannot be cancelled, so the reads run on a dedicated
/// thread. When the deadline passes first, the caller gets an incomplete snapshot and
/// this handle, and must not write to the pasteboard until `finished()` returns — a
/// write while the read is still running would race it (ARCHITECTURE §3.4).
public final class SnapshotRead: @unchecked Sendable {
    private let lock = NSLock()
    private var result: PasteboardSnapshot?
    private var waiters: [CheckedContinuation<PasteboardSnapshot, Never>] = []

    init() {}

    public var isFinished: Bool { lock.withLock { result != nil } }

    /// Waits for the read to end; returns what it read.
    public func finished() async -> PasteboardSnapshot {
        await withCheckedContinuation { continuation in
            let ready: PasteboardSnapshot? = lock.withLock {
                if let result { return result }
                waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    private var finishHandlers: [@Sendable () -> Void] = []

    /// Calls `handler` once the read ends — at once if it already has.
    func onFinish(_ handler: @escaping @Sendable () -> Void) {
        let done: Bool = lock.withLock {
            if result != nil { return true }
            finishHandlers.append(handler)
            return false
        }
        if done { handler() }
    }

    func finish(_ snapshot: PasteboardSnapshot) {
        let (pending, handlers): ([CheckedContinuation<PasteboardSnapshot, Never>], [@Sendable () -> Void]) = lock.withLock {
            result = snapshot
            defer { waiters.removeAll(); finishHandlers.removeAll() }
            return (waiters, finishHandlers)
        }
        for waiter in pending { waiter.resume(returning: snapshot) }
        for handler in handlers { handler() }
    }
}

/// Resumes a continuation the first time only.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func resume(_ value: T) {
        let pending: CheckedContinuation<T, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

public enum PasteboardSnapshotter {
    /// The outcome of a snapshot within a deadline.
    public struct Outcome: Sendable {
        public var snapshot: PasteboardSnapshot
        /// Set when the deadline passed with a read still running.
        public var pendingRead: SnapshotRead?

        public init(snapshot: PasteboardSnapshot, pendingRead: SnapshotRead?) {
            self.snapshot = snapshot
            self.pendingRead = pendingRead
        }
    }

    /// Reads every item and type of `pasteboard` within `deadline`.
    ///
    /// Refuses to read at all unless the access policy is Always Allow.
    public static func take<C: Clock>(
        from pasteboard: any PasteboardClient,
        deadline: Duration,
        sizeCap: Int = PasteboardSnapshot.defaultSizeCap,
        clock: C
    ) async -> Outcome where C.Duration == Duration {
        let startCount = pasteboard.changeCount()
        guard pasteboard.accessBehavior().allowsReading else {
            return Outcome(
                snapshot: PasteboardSnapshot(items: [], changeCount: startCount, incompleteReason: .readingNotAllowed),
                pendingRead: nil
            )
        }

        let read = SnapshotRead()
        let thread = Thread {
            read.finish(readAll(from: pasteboard, startCount: startCount, sizeCap: sizeCap))
        }
        thread.name = "Pasteboard snapshot"
        thread.start()

        // A race resolved once: the read finishing, or the deadline. Not a task group —
        // a group waits for every child, and a child waiting on a blocked read would hold
        // the snapshot past its deadline indefinitely.
        let finishedInTime = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            read.onFinish { once.resume(true) }
            Task {
                try? await clock.sleep(for: deadline)
                once.resume(false)
            }
        }
        if finishedInTime || read.isFinished {
            return Outcome(snapshot: await read.finished(), pendingRead: nil)
        }
        return Outcome(
            snapshot: PasteboardSnapshot(items: [], changeCount: startCount, incompleteReason: .timedOut),
            pendingRead: read
        )
    }

    static func readAll(from pasteboard: any PasteboardClient, startCount: Int, sizeCap: Int) -> PasteboardSnapshot {
        var items: [PasteboardItemData] = []
        var total = 0
        var reason: PasteboardSnapshot.IncompleteReason?
        for (index, types) in pasteboard.itemTypes().enumerated() {
            var entries: [PasteboardItemData.Entry] = []
            for type in types {
                if PasteboardMarkers.isRegeneratedAlias(type) { continue }
                guard !PasteboardMarkers.isFilePromise(type) else {
                    reason = reason ?? .skippedType
                    continue
                }
                guard let data = pasteboard.data(forType: type, item: index) else {
                    reason = reason ?? .skippedType
                    continue
                }
                total += data.count
                if total > sizeCap {
                    return PasteboardSnapshot(items: [], changeCount: startCount, incompleteReason: .tooLarge)
                }
                entries.append(.init(type: type, data: data))
            }
            items.append(PasteboardItemData(entries: entries))
        }
        if pasteboard.changeCount() != startCount { reason = .changedWhileReading }
        return PasteboardSnapshot(items: items, changeCount: startCount, incompleteReason: reason)
    }

    public enum RestoreOutcome: String, Codable, Sendable {
        case restored
        /// The user copied something after Quill's write: their copy wins.
        case skippedChangedSinceWrite
        /// Nothing complete to put back; the clipboard keeps the rewrite.
        case skippedIncomplete
    }

    /// Puts `snapshot` back — only if it is complete and the pasteboard still holds
    /// what Quill wrote (`changeCount == writtenChangeCount`, ARCHITECTURE §3.2 step 9).
    ///
    /// The restore is marked transient and kept off Universal Clipboard: no API says
    /// whether the original was host-only, so a restore must never push it to other
    /// devices.
    @discardableResult
    public static func restore(
        _ snapshot: PasteboardSnapshot?,
        to pasteboard: any PasteboardClient,
        ifChangeCountIs writtenChangeCount: Int
    ) -> RestoreOutcome {
        guard let snapshot, snapshot.isComplete else { return .skippedIncomplete }
        guard pasteboard.changeCount() == writtenChangeCount else { return .skippedChangedSinceWrite }
        var items = snapshot.items
        if !items.isEmpty, items[0].data(forType: PasteboardMarkers.transient) == nil {
            items[0].entries.append(.init(type: PasteboardMarkers.transient, data: Data()))
        }
        pasteboard.write(items, hostOnly: true)
        return .restored
    }
}
