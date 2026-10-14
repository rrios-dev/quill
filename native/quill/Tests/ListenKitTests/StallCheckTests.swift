import Foundation
import Testing

@testable import ListenKit

/// The watchdog's judgement: a capture that stops delivering is dead, never a quiet meeting.
@Suite("Stall check")
struct StallCheckTests {
    private let start = ContinuousClock.now
    private func at(_ seconds: Int) -> ContinuousClock.Instant { start.advanced(by: .seconds(seconds)) }

    @Test("a counter that keeps moving is fine")
    func movingIsFine() {
        var check = StallCheck()
        for (round, value) in [3, 9, 15, 21].enumerated() {
            #expect(check.observe(value, timeout: .seconds(3), now: at(round * 2)) == .fine)
        }
    }

    @Test("a counter stuck past the timeout is a stall, reported once")
    func stuckIsAStall() {
        var check = StallCheck()
        #expect(check.observe(10, timeout: .seconds(3), now: at(0)) == .fine)
        #expect(check.observe(10, timeout: .seconds(3), now: at(2)) == .fine)
        #expect(check.observe(10, timeout: .seconds(3), now: at(5)) == .stalled(firstTime: true))
        #expect(check.observe(10, timeout: .seconds(3), now: at(7)) == .fine)
        #expect(check.observe(10, timeout: .seconds(3), now: at(10)) == .stalled(firstTime: false))
        #expect(check.observe(11, timeout: .seconds(3), now: at(12)) == .recovered)
    }

    @Test("a rebuilt capture that never delivers is judged again, not taken as recovered")
    func rebuiltSilentCaptureStallsAgain() {
        // The new tap counts from zero; a fresh check with last -1 would read 0 as movement.
        var check = StallCheck(healthy: false, last: 0)
        #expect(check.observe(0, timeout: .seconds(3), now: at(0)) == .fine)
        #expect(check.observe(0, timeout: .seconds(3), now: at(4)) == .stalled(firstTime: false))
    }

    @Test("a capture that never started stalls too")
    func neverStartedStalls() {
        var check = StallCheck()
        #expect(check.observe(0, timeout: .seconds(3), now: at(0)) == .fine)
        #expect(check.observe(0, timeout: .seconds(3), now: at(2)) == .fine)
        #expect(check.observe(0, timeout: .seconds(3), now: at(6)) == .stalled(firstTime: true))
    }
}
