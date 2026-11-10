import Testing

@testable import ListenKit

/// Live passes keep the two-minute rhythm while they are cheap and space out as they grow
/// (EFFICIENCY.md E2).
@Suite("Live pass schedule")
struct LivePassScheduleTests {
    let schedule = LivePassSchedule()

    @Test("a cheap pass keeps the two-minute rhythm a name given early relies on")
    func cheapPasses() {
        #expect(schedule.interval(after: .seconds(1)) == .seconds(120))
        #expect(schedule.interval(after: .seconds(8)) == .seconds(120))
    }

    @Test("a costly pass waits fifteen times its own length, so passes take a fifteenth of the time")
    func costlyPasses() {
        #expect(schedule.interval(after: .seconds(19)) == .seconds(285))
        #expect(schedule.interval(after: .milliseconds(12_500)) == .milliseconds(187_500))
    }

    @Test("never more than ten minutes, however slow the Mac")
    func ceiling() {
        #expect(schedule.interval(after: .seconds(90)) == .seconds(600))
    }
}
