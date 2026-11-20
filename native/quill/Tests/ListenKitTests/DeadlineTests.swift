import Foundation
import Testing

@testable import ListenKit

/// The end of a meeting must go on when one of its steps never returns.
@Suite("Deadline")
struct DeadlineTests {
    @Test("work that finishes in time gives its value")
    func inTime() async {
        let value = await Deadline.run(within: .seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test("work that never returns gives nil at the limit, without waiting for it")
    func stuck() async {
        let clock = ContinuousClock()
        let began = clock.now
        // A call blocked outside Swift's reach: it ignores cancellation.
        let value = await Deadline.run(within: .milliseconds(200)) { () -> Int in
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return 1
        }
        #expect(value == nil)
        #expect(began.duration(to: clock.now) < .seconds(2))
    }

    @Test("work that honours cancellation is cancelled at the limit")
    func cancelled() async {
        let seen = Flag()
        let value = await Deadline.run(within: .milliseconds(100)) { () -> Int in
            try? await Task.sleep(for: .seconds(30))
            if Task.isCancelled { seen.set() }
            return 1
        }
        #expect(value == nil)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(seen.isSet)
    }

    @Test("an error thrown in time reaches the caller")
    func throwsInTime() async {
        struct Failed: Error {}
        await #expect(throws: Failed.self) {
            _ = try await Deadline.run(within: .seconds(5)) { () async throws -> Int in throw Failed() }
        }
    }

    @Test("throwing work that never returns gives nil, not an error")
    func throwingStuck() async throws {
        let value = try await Deadline.run(within: .milliseconds(100)) { () async throws -> Int in
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return 1
        }
        #expect(value == nil)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
