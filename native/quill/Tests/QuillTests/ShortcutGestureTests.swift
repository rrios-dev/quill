import Foundation
import Testing

@testable import Quill

/// The rewrite shortcut: a tap rewrites, a hold starts dictation, which goes on after the
/// keys are let go until the next press (EFFICIENCY.md E8, J-19).
@Suite("Shortcut gesture")
struct ShortcutGestureTests {
    let start = ContinuousClock.now
    func at(_ milliseconds: Int) -> ContinuousClock.Instant { start + .milliseconds(milliseconds) }

    @Test("a quick press and release is the rewrite it always was")
    func tap() {
        var gesture = ShortcutGesture()
        #expect(gesture.press(at: at(0)) == .arm)
        #expect(gesture.thresholdPassed(at: at(200)) == .none, "a timer that fires early does nothing")
        #expect(gesture.release(at: at(150)) == .tap)
        #expect(gesture.phase == .idle)
    }

    @Test("held as long as one likes while speaking, letting go does not stop it: the next press does")
    func holdThenPress() {
        var gesture = ShortcutGesture()
        _ = gesture.press(at: at(0))
        #expect(gesture.thresholdPassed(at: at(450)) == .startListening)
        #expect(gesture.press(at: at(800)) == .none, "key repeat while held")
        #expect(gesture.release(at: at(6_000)) == .none)
        #expect(gesture.phase == .handsFree)
        #expect(gesture.press(at: at(20_000)) == .finish)
        #expect(gesture.phase == .idle)
    }

    @Test("let go right after the microphone opens: it keeps listening until the next press")
    func handsFree() {
        var gesture = ShortcutGesture()
        _ = gesture.press(at: at(0))
        _ = gesture.thresholdPassed(at: at(450))
        #expect(gesture.release(at: at(700)) == .none)
        #expect(gesture.phase == .handsFree)
        #expect(gesture.press(at: at(9_000)) == .finish)
        #expect(gesture.release(at: at(9_100)) == .none, "the finishing press's release is not a tap")
        #expect(gesture.phase == .idle)
    }

    @Test("released at the threshold before its timer ran is still a hold")
    func lateTimer() {
        var gesture = ShortcutGesture()
        _ = gesture.press(at: at(0))
        #expect(gesture.release(at: at(460)) == .startListening)
        #expect(gesture.phase == .handsFree)
    }
}
