import Foundation

/// Waits for work at most a given time, so a step that never returns cannot hold what
/// comes after it.
///
/// Measured on 2026-11-13: a 33 min Teams meeting stayed on "Telling voices apart…" until
/// Quill was restarted, and its voices were lost with the audio, which lives only in memory.
/// Every step at the end of a meeting waited without a limit.
public enum Deadline {
    /// Runs `operation` and returns its value, or nil when `limit` passes first.
    ///
    /// The operation is cancelled at the limit but keeps running if it does not honour
    /// cancellation: a call blocked in a framework cannot be stopped, only left behind.
    /// Not a task group — a group waits for every child, and a child stuck in such a
    /// call would hold the caller past its limit (`PasteboardSnapshotter.take`).
    public static func run<T: Sendable>(
        within limit: Duration,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let once = ResumeOnce<T?>()
        return await withCheckedContinuation { continuation in
            once.arm(continuation)
            let work = Task { once.resume(await operation()) }
            let timer = Task {
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                work.cancel()
                once.resume(nil)
            }
            once.onResume { timer.cancel() }
        }
    }

    /// `run(within:_:)` for work that throws: nil at the limit, its error otherwise.
    public static func run<T: Sendable>(
        within limit: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        let outcome = await run(within: limit) { () -> Result<T, any Error> in
            do { return .success(try await operation()) } catch { return .failure(error) }
        }
        return try outcome?.get()
    }
}

/// A continuation resumed by whichever side of a race finishes first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var resumed = false
    private var cleanup: (@Sendable () -> Void)?

    func arm(_ continuation: CheckedContinuation<Value, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    /// Runs `body` once the race is decided, at once if it already is.
    func onResume(_ body: @escaping @Sendable () -> Void) {
        let decided = lock.withLock { () -> Bool in
            if !resumed { cleanup = body }
            return resumed
        }
        if decided { body() }
    }

    func resume(_ value: Value) {
        let (continuation, cleanup) = lock.withLock { () -> (CheckedContinuation<Value, Never>?, (@Sendable () -> Void)?) in
            guard !resumed else { return (nil, nil) }
            resumed = true
            defer {
                self.continuation = nil
                self.cleanup = nil
            }
            return (self.continuation, self.cleanup)
        }
        continuation?.resume(returning: value)
        cleanup?()
    }
}
