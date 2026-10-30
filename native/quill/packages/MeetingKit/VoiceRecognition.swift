import Foundation
import ListenKit

/// One meeting's voice of a person: what the people directory keeps instead of audio.
public struct VoiceSample: Codable, Hashable, Sendable {
    /// The meeting it was heard in: one sample per person and meeting, replaced when the
    /// voice is corrected there.
    public var meetingID: UUID
    public var voiceprint: Voiceprint

    public init(meetingID: UUID, voiceprint: Voiceprint) {
        self.meetingID = meetingID
        self.voiceprint = voiceprint
    }
}

/// Recognising people a meeting has heard before, by voice (VOICES.md S2, J-02, J-03).
///
/// Every voice of a finished meeting has per-sentence WeSpeaker voiceprints (S1); their
/// mean is the voice's print. A person keeps one print per meeting where the user named
/// them. A new voice close enough to a person's prints is *proposed* as that person
/// ("is this Fran, Product Owner?"), never named on its own.
///
/// Measured on the owner's own meetings (2026-10-30, three Teams calls with prints, eleven
/// voices): the same voice in two meetings 0.85; every pair of different voices 0.47 or
/// less, except two voices of one meeting the diarizer split from one person (0.62).
public enum VoiceRecognition {
    /// Below this, a voice is not proposed as anybody.
    public static let threshold: Float = 0.6
    /// A rejected proposal removes the person's samples at least this close to the voice:
    /// that close, they are the same voice, so the sample was named wrongly.
    public static let sameVoice: Float = 0.75
    /// Sentences a voice needs before its print is trusted.
    public static let minimumSentences = 2

    public struct Suggestion: Equatable, Sendable {
        public let personID: UUID
        public let similarity: Float
    }

    /// Each voice of the others' channel with enough measured sentences, as one print:
    /// the duration-weighted mean of its sentences.
    public static func voices(of transcript: Transcript) -> [String: Voiceprint] {
        var sums: [String: [Float]] = [:]
        var counts: [String: Int] = [:]
        for segment in transcript.segments where segment.channel == .others {
            guard let label = segment.speaker, let print = segment.voiceprint?.values, !print.isEmpty else { continue }
            let unit = normalized(print)
            let weight = Float(max(segment.end - segment.start, 0.5))
            var sum = sums[label] ?? [Float](repeating: 0, count: unit.count)
            guard sum.count == unit.count else { continue }
            for index in unit.indices { sum[index] += unit[index] * weight }
            sums[label] = sum
            counts[label, default: 0] += 1
        }
        return sums.reduce(into: [:]) { result, entry in
            guard counts[entry.key, default: 0] >= minimumSentences else { return }
            result[entry.key] = Voiceprint(normalized(entry.value))
        }
    }

    /// How alike a voice is to a person: the closest of their samples.
    public static func similarity(_ voice: Voiceprint, to person: Person) -> Float {
        (person.voices ?? []).map { cosine(voice.values, $0.voiceprint.values) }.max() ?? -1
    }

    /// The person each unnamed voice may be, at most one voice per person: when two
    /// voices sound like the same person, the closer one gets the proposal.
    ///
    /// - Parameters:
    ///   - voices: the meeting's voices (`voices(of:)`).
    ///   - named: labels the user already named; they are not proposed and their people
    ///     are taken.
    ///   - rejected: label → people the user said it is not.
    public static func suggestions(
        voices: [String: Voiceprint],
        people: [Person],
        named: [String: UUID],
        rejected: [String: [UUID]] = [:]
    ) -> [String: Suggestion] {
        let taken = Set(named.values)
        var candidates: [(label: String, suggestion: Suggestion)] = []
        for (label, voice) in voices where named[label] == nil {
            for person in people where !taken.contains(person.id) && !(rejected[label] ?? []).contains(person.id) {
                let similarity = similarity(voice, to: person)
                if similarity >= threshold {
                    candidates.append((label, Suggestion(personID: person.id, similarity: similarity)))
                }
            }
        }
        var result: [String: Suggestion] = [:]
        var used: Set<UUID> = []
        for candidate in candidates.sorted(by: { $0.suggestion.similarity > $1.suggestion.similarity }) {
            guard result[candidate.label] == nil, !used.contains(candidate.suggestion.personID) else { continue }
            result[candidate.label] = candidate.suggestion
            used.insert(candidate.suggestion.personID)
        }
        return result
    }

    /// Named voices that sound like somebody else: the same voice was given another
    /// person's name in an earlier meeting, so one of the two names is wrong. Measured on
    /// the owner's meetings (2026-10-30): the voice named "Fran" that day was the one named
    /// "Hugo" four days before, 0.83 alike, and 0.24 from the other "Fran".
    public static func conflicts(
        voices: [String: Voiceprint],
        people: [Person],
        named: [String: UUID],
        in meeting: UUID
    ) -> [String: Suggestion] {
        var result: [String: Suggestion] = [:]
        for (label, personID) in named {
            guard let voice = voices[label] else { continue }
            let others = people.map { person -> Person in
                var person = person
                person.voices = person.voices?.filter { $0.meetingID != meeting }
                return person
            }
            guard let own = others.first(where: { $0.id == personID }), !(own.voices ?? []).isEmpty,
                  similarity(voice, to: own) < threshold else { continue }
            let best = others.filter { $0.id != personID }
                .map { Suggestion(personID: $0.id, similarity: similarity(voice, to: $0)) }
                .max { $0.similarity < $1.similarity }
            if let best, best.similarity >= sameVoice { result[label] = best }
        }
        return result
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : vector
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        let a = normalized(a), b = normalized(b)
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
