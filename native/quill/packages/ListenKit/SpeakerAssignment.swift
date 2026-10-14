import Foundation

/// A stretch of time attributed to one voice by a diarizer.
public struct SpeakerTurn: Sendable, Equatable {
    public var speaker: String
    public var start: Double
    public var end: Double

    public init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

extension SpeakerTurn {
    /// Folds voices that barely speak into the people speaking around them.
    ///
    /// The diarizer invents a voice where two people talk at once: the mixture sounds like
    /// nobody it has heard. Measured on the meeting bench (TESTING-MEETINGS.md): five real
    /// people came out as seven, the two extra holding 5–7 s each, almost all of it
    /// interruptions; captured live through the tap, one extra voice of 13 s (4 % of the
    /// speech) held a little of all five people. Their voiceprints cannot say whose they are — two different real
    /// women were more alike (0.55) than either ghost was to the person it came from — but
    /// time can: each of their turns goes to the main voice it overlaps most, or the
    /// nearest one.
    ///
    /// A voice is minor only when it is small both ways: under `minimumShare` of the
    /// speech and under `minimumSeconds`. The cost, accepted: a real person who says one
    /// short sentence in a long meeting is folded into a neighbour.
    public static func absorbingMinorVoices(_ turns: [SpeakerTurn], minimumShare: Double = 0.05,
                                            minimumSeconds: Double = 15) -> [SpeakerTurn] {
        var seconds: [String: Double] = [:]
        for turn in turns { seconds[turn.speaker, default: 0] += turn.end - turn.start }
        let total = seconds.values.reduce(0, +)
        let minor = Set(seconds.filter { $0.value < minimumShare * total && $0.value < minimumSeconds }.keys)
        guard !minor.isEmpty, minor.count < seconds.count else { return turns }
        let main = turns.filter { !minor.contains($0.speaker) }
        return turns.map { turn in
            guard minor.contains(turn.speaker) else { return turn }
            func overlap(_ other: SpeakerTurn) -> Double { max(0, min(turn.end, other.end) - max(turn.start, other.start)) }
            func gap(_ other: SpeakerTurn) -> Double { max(other.start - turn.end, turn.start - other.end, 0) }
            let host = main.max { a, b in
                overlap(a) != overlap(b) ? overlap(a) < overlap(b) : gap(a) > gap(b)
            }
            guard let host else { return turn }
            return SpeakerTurn(speaker: host.speaker, start: turn.start, end: turn.end)
        }
    }
}

extension Transcript {
    /// Splits the `others` channel by voice.
    ///
    /// The transcriber cuts segments at pauses, not at changes of speaker, so one segment
    /// can hold two people. Each word goes to the turn it overlaps most, or the nearest
    /// turn when it overlaps none; consecutive words of the same voice become a segment.
    /// Labels are renumbered in order of first appearance ("speaker-1" speaks first), so
    /// they read naturally and stay stable however the diarizer named its clusters.
    ///
    /// `me` segments are left as they are: that split is exact and comes from hardware.
    ///
    /// `renumbering: false` keeps the turns' own labels: when they come from a
    /// `SpeakerLabeler`, the names the user gave during the meeting are keyed by them.
    public func assigningSpeakers(_ turns: [SpeakerTurn], renumbering: Bool = true) -> Transcript {
        guard !turns.isEmpty else { return self }
        let sortedTurns = turns.sorted { $0.start < $1.start }
        var result = self
        var rebuilt: [TranscriptSegment] = []

        for segment in segments {
            guard segment.channel == .others else {
                rebuilt.append(segment)
                continue
            }
            let words = segment.words.isEmpty
                ? [TimedWord(text: segment.text, start: segment.start, end: segment.end)]
                : segment.words
            var current: TranscriptSegment?
            for word in words {
                let speaker = Self.speaker(for: word, in: sortedTurns)
                if var open = current, open.speaker == speaker {
                    open.text = Self.join(open.text, word.text)
                    open.end = word.end
                    open.words.append(word)
                    current = open
                } else {
                    if let open = current { rebuilt.append(open) }
                    current = TranscriptSegment(
                        channel: .others,
                        start: word.start,
                        end: word.end,
                        text: word.text.trimmingCharacters(in: .whitespaces),
                        speaker: speaker,
                        words: [word]
                    )
                }
            }
            if let open = current { rebuilt.append(open) }
        }

        guard renumbering else {
            result.segments = rebuilt
            return result
        }
        // Renumber by first appearance in speaking order.
        var renamed: [String: String] = [:]
        for segment in rebuilt.sorted(by: { $0.start < $1.start }) {
            guard let speaker = segment.speaker, renamed[speaker] == nil else { continue }
            renamed[speaker] = "speaker-\(renamed.count + 1)"
        }
        result.segments = rebuilt.map { segment in
            var segment = segment
            segment.speaker = segment.speaker.flatMap { renamed[$0] }
            return segment
        }
        return result
    }

    static func speaker(for word: TimedWord, in turns: [SpeakerTurn]) -> String {
        var best: (speaker: String, overlap: Double)?
        for turn in turns {
            let overlap = min(word.end, turn.end) - max(word.start, turn.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (turn.speaker, overlap) }
        }
        if let best { return best.speaker }
        // No overlap: a word in a gap between turns belongs to the closest one.
        let middle = (word.start + word.end) / 2
        return turns.min { distance(middle, $0) < distance(middle, $1) }!.speaker
    }

    static func distance(_ time: Double, _ turn: SpeakerTurn) -> Double {
        time < turn.start ? turn.start - time : (time > turn.end ? time - turn.end : 0)
    }

    /// Joins word pieces the way the model emitted them: a piece that starts with a space
    /// is a new word; one that does not continues the previous word or is punctuation.
    static func join(_ text: String, _ piece: String) -> String {
        guard !text.isEmpty else { return piece.trimmingCharacters(in: .whitespaces) }
        return piece.first?.isWhitespace == true || piece.first?.isLetter == true && !(text.last?.isLetter ?? false)
            ? text + (piece.first?.isWhitespace == true ? piece : " " + piece)
            : text + piece
    }
}
