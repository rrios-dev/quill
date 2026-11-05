import Foundation

/// A voice that holds two people Quill has met before, found sentence by sentence.
///
/// The diarizer can merge two people who sound alike into one voice, and the voice's mean
/// print then sits between them: close enough to neither person to be proposed as anybody
/// (`VoiceRecognition`). Each sentence, though, keeps its own WeSpeaker print, and that
/// model tells alike voices apart where the diarizer's cannot (VOICES.md S1). So every
/// sentence is compared with the people's stored prints; when two of them each clearly
/// own enough sentences, the voice is proposed as two people — the user's marks of S1,
/// given by the profiles instead (VOICES.md S5).
public struct KnownSplit<ID: Hashable & Sendable>: Equatable, Sendable {
    /// The person keeping the voice's label: the one with more sentences.
    public let kept: ID
    /// The person the `moved` sentences go to.
    public let other: ID
    /// Segment indices that belong to `other`.
    public let moved: [Int]

    public init(kept: ID, other: ID, moved: [Int]) {
        self.kept = kept
        self.other = other
        self.moved = moved
    }
}

extension Transcript {
    /// Tuning of `knownSplit`, measured on the bench and the owner's meetings (VOICES.md S5).
    public struct KnownSplitRule: Sendable {
        /// A sentence counts as a person's only this close to their nearest stored print.
        public var threshold: Float
        /// …and this much closer to them than to anybody else.
        public var margin: Float
        /// Sentences each of the two people must own before a split is proposed.
        public var minimumSentences: Int

        public init(threshold: Float, margin: Float, minimumSentences: Int) {
            self.threshold = threshold
            self.margin = margin
            self.minimumSentences = minimumSentences
        }

        public static let standard = KnownSplitRule(threshold: 0.5, margin: 0.1, minimumSentences: 2)
    }

    /// The two known people a voice holds, if its sentences say so; nil otherwise.
    ///
    /// The sentences that clearly belong to one person pin the two sides; every other
    /// measured sentence goes to the nearer side's centre in this meeting, not to the
    /// stored prints — the meeting's own sentences share its microphones and line
    /// (`VoiceSplit.twoWay` with known pieces). Sentences without a print stay where they are.
    ///
    /// - Parameter profiles: each person's stored prints, one per earlier meeting.
    public func knownSplit<ID: Hashable & Sendable>(of label: String, profiles: [ID: [Voiceprint]],
                                                   rule: KnownSplitRule = .standard) -> KnownSplit<ID>? {
        let measured = segments.indices.filter {
            segments[$0].channel == .others && segments[$0].speaker == label && segments[$0].voiceprint != nil
        }
        let people = profiles.filter { !$0.value.isEmpty }.map { (id: $0.key, prints: $0.value.map { VoiceSplit.normalized($0.values) }) }
        guard measured.count >= 2 * rule.minimumSentences, people.count >= 2 else { return nil }

        var owner: [Int: ID] = [:]
        for index in measured {
            let print = VoiceSplit.normalized(segments[index].voiceprint!.values)
            let scores = people.map { person in
                (id: person.id, score: person.prints.map { $0.count == print.count ? VoiceSplit.dot(print, $0) : -1 }.max() ?? -1)
            }.sorted { $0.score > $1.score }
            guard let best = scores.first, best.score >= rule.threshold,
                  best.score - (scores.dropFirst().first?.score ?? -1) >= rule.margin else { continue }
            owner[index] = best.id
        }
        var votes: [ID: Int] = [:]
        var first: [ID: Int] = [:]
        for (index, id) in owner {
            votes[id, default: 0] += 1
            first[id] = min(first[id] ?? index, index)
        }
        // A tie goes to whoever spoke first, so the same meeting always gives the same proposal.
        let ranked = votes.filter { $0.value >= rule.minimumSentences }
            .sorted { $0.value != $1.value ? $0.value > $1.value : first[$0.key]! < first[$1.key]! }
        guard ranked.count >= 2 else { return nil }
        let (kept, other) = (ranked[0].key, ranked[1].key)

        var known: [Int: Int] = [:]
        for (position, index) in measured.enumerated() {
            if owner[index] == kept { known[position] = 0 } else if owner[index] == other { known[position] = 1 }
        }
        let groups = VoiceSplit.twoWay(measured.map { segments[$0].voiceprint!.values }, known: known)
        let moved = measured.indices.filter { groups[$0] == 1 }.map { measured[$0] }
        return KnownSplit(kept: kept, other: other, moved: moved)
    }
}
