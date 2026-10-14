import AppKit
import Testing

@testable import Quill

/// How the meeting window arranges itself for the space it gets (`MeetingLayout`).
@Suite("Meeting window layout")
struct MeetingLayoutTests {
    @Test("wide is columns, tall is stacked, small is tabs")
    func layouts() {
        #expect(MeetingLayout(size: CGSize(width: 1440, height: 900)) == .columns)
        // The owner's portrait display, whole and halved by the tiler.
        #expect(MeetingLayout(size: CGSize(width: 1080, height: 2400)) == .stacked)
        #expect(MeetingLayout(size: CGSize(width: 1080, height: 1180)) == .tabs(peopleBeside: true))
        #expect(MeetingLayout(size: CGSize(width: 640, height: 520)) == .tabs(peopleBeside: false))
        #expect(MeetingLayout(size: CGSize(width: 480, height: 2300)) == .stacked)
    }

    @Test("a boundary crossed by a few points does not flip the layout back and forth")
    func hysteresis() {
        // Just under the columns threshold: still columns if it was columns.
        #expect(MeetingLayout(size: CGSize(width: 1200, height: 900), from: .columns) == .columns)
        #expect(MeetingLayout(size: CGSize(width: 1200, height: 900), from: .tabs(peopleBeside: true)) == .tabs(peopleBeside: true))
        // Just under the portrait ratio: still stacked if it was stacked.
        #expect(MeetingLayout(size: CGSize(width: 1000, height: 1100), from: .stacked) == .stacked)
        #expect(MeetingLayout(size: CGSize(width: 1000, height: 1100)) == .tabs(peopleBeside: true))
    }

    @Test("the window can be made small enough for any tile")
    func minimum() {
        #expect(MeetingLayout.minimumSize.width <= 480)
        #expect(MeetingLayout.initialSize(on: NSRect(x: 0, y: 0, width: 1080, height: 2560)).width <= 1080)
    }
}
