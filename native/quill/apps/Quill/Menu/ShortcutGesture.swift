import Foundation

/// What one press of the rewrite shortcut means (EFFICIENCY.md E8; J-18, J-19): a tap
/// rewrites the selection, as Quill always has; holding it starts dictation, which goes
/// on after the keys are let go, until the shortcut is pressed again.
///
/// Whatever combination the user recorded: the app registers that one and feeds its
/// press, its release and the threshold timer here. Pure: it answers what to do.
struct ShortcutGesture: Equatable {
    /// How long the keys must stay down for a hold. Under it, a press is a tap.
    static let holdThreshold: Duration = .milliseconds(450)

    enum Phase: Equatable {
        case idle
        /// Down, not yet a hold.
        case pressed(at: ContinuousClock.Instant)
        /// Held past the threshold: listening, the keys still down.
        case holding
        /// Listening, the keys let go: the next press finishes.
        case handsFree
    }

    enum Action: Equatable {
        case none
        /// The keys went down: dictation may load its model, without the microphone.
        case arm
        /// Released before the threshold: rewrite the selection, and drop what was armed.
        case tap
        /// Held past the threshold: open the microphone.
        case startListening
        /// Finish what was said and rewrite it.
        case finish
    }

    private(set) var phase: Phase = .idle

    mutating func press(at now: ContinuousClock.Instant) -> Action {
        switch phase {
        case .idle:
            phase = .pressed(at: now)
            return .arm
        case .handsFree:
            phase = .idle
            return .finish
        case .pressed, .holding:
            // Key repeat or a second press while held: nothing new.
            return .none
        }
    }

    /// The threshold timer fired.
    mutating func thresholdPassed(at now: ContinuousClock.Instant) -> Action {
        guard case .pressed(let since) = phase, since.duration(to: now) >= Self.holdThreshold else { return .none }
        phase = .holding
        return .startListening
    }

    mutating func release(at now: ContinuousClock.Instant) -> Action {
        switch phase {
        case .pressed(let since):
            // A release right at the threshold, before its timer ran, is still a hold.
            if since.duration(to: now) >= Self.holdThreshold {
                phase = .handsFree
                return .startListening
            }
            phase = .idle
            return .tap
        case .holding:
            // Letting go never stops it (J-19): the next press does.
            phase = .handsFree
            return .none
        case .idle, .handsFree:
            return .none
        }
    }

    /// Dictation ended on its own (cancelled, failed, finished from the menu).
    mutating func reset() { phase = .idle }

    /// Listening already, started from the menu: the next press finishes.
    static func handsFreeNow() -> ShortcutGesture {
        var gesture = ShortcutGesture()
        gesture.phase = .handsFree
        return gesture
    }
}
