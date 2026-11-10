import Foundation

/// When the next live diarization pass runs.
///
/// A pass separates everything heard so far, so it takes longer as the meeting grows:
/// measured on 2026-11-10 (EFFICIENCY.md E2), 1 s at minute 2, 8 s at minute 20, 19 s at
/// minute 60. Every two minutes, as before, that is 16 % of a core at the end of an hour
/// and 295 s of CPU over it. Spacing the passes by what the last one cost keeps them
/// under a fixed share of the time, on a fast Mac or a slow one, while short meetings
/// keep the two-minute rhythm a name given early relies on.
public struct LivePassSchedule: Sendable {
    /// Before the first pass: enough speech for the voices to show.
    public var first: Duration = .seconds(60)
    /// The shortest wait between passes.
    public var minimum: Duration = .seconds(120)
    /// The longest: a new voice is named at most this late.
    public var maximum: Duration = .seconds(600)
    /// The share of the time passes may take, at most.
    public var budget: Double = 1.0 / 15

    public init() {}

    /// The wait after a pass that took `lastPass`.
    public func interval(after lastPass: Duration) -> Duration {
        let seconds = Double(lastPass.components.seconds) + Double(lastPass.components.attoseconds) / 1e18
        let wanted = Duration.milliseconds(Int64((seconds / budget * 1000).rounded()))
        return min(max(wanted, minimum), maximum)
    }
}
