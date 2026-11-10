import Foundation

/// Voiceprints of the others' sentences measured while the meeting goes on, so the end
/// of the meeting does not measure them all at once.
///
/// Measured on 2026-11-10 (EFFICIENCY.md): a sentence takes about 60 ms to measure, an
/// hour holds several hundred, and they were all measured after "stop", one by one. A
/// sentence the final separation leaves whole keeps the print it got when it was heard;
/// one it splits between two people has new times and is measured then.
///
/// Keyed by the stretch of audio measured, exactly: the same samples give the same print,
/// any other stretch is another sentence.
public struct SentencePrints: Sendable {
    private struct Span: Hashable, Sendable {
        let start: Double
        let end: Double
    }

    private var prints: [Span: Voiceprint] = [:]

    public init() {}

    public var count: Int { prints.count }

    /// The audio a segment's print is measured on once voices are assigned: from its
    /// first word to its last (`Transcript.assigningSpeakers` rebuilds a segment from its
    /// words), or the whole segment when the model timed no words.
    public static func span(of segment: TranscriptSegment) -> (start: Double, end: Double) {
        (segment.words.first?.start ?? segment.start, segment.words.last?.end ?? segment.end)
    }

    public mutating func keep(_ print: Voiceprint, from start: Double, to end: Double) {
        prints[Span(start: start, end: end)] = print
    }

    public func print(from start: Double, to end: Double) -> Voiceprint? {
        prints[Span(start: start, end: end)]
    }
}
