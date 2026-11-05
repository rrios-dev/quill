import Foundation
import Testing

@testable import ListenKit

/// A voice that holds two people met before, told apart by their stored prints.
@Suite("Known voices")
struct KnownVoicesTests {
    /// Ana's stored print leans towards (1, 0), Bea's towards (0.6, 0.8).
    static let profiles: [String: [Voiceprint]] = [
        "ana": [Voiceprint([1, 0])],
        "bea": [Voiceprint([0.6, 0.8]), Voiceprint([0.55, 0.83])],
    ]
    static let ana: [[Float]] = [[1, 0.05], [0.98, 0.12], [1, -0.02], [0.97, 0.1]]
    static let bea: [[Float]] = [[0.62, 0.78], [0.58, 0.8], [0.65, 0.76]]

    static func transcript(_ prints: [[Float]?], speaker: String = "speaker-1") -> Transcript {
        Transcript(startedAt: Date(), locale: "es_ES", source: "t", segments: prints.enumerated().map { index, print in
            TranscriptSegment(channel: .others, start: Double(index) * 3, end: Double(index) * 3 + 2, text: "…",
                              speaker: speaker, voiceprint: print.map(Voiceprint.init))
        })
    }

    @Test("a voice holding two known people is split: the one with more sentences keeps it")
    func split() {
        let transcript = Self.transcript(Self.ana + Self.bea)
        let split = transcript.knownSplit(of: "speaker-1", profiles: Self.profiles)
        #expect(split == KnownSplit(kept: "ana", other: "bea", moved: [4, 5, 6]))
    }

    @Test("a sentence close to neither person follows the nearer side of this meeting")
    func ambiguous() {
        // (0.85, 0.53) is 0.85 from Ana and 0.93 from Bea's print: no clear owner, but nearer Bea's sentences.
        let transcript = Self.transcript(Self.ana + Self.bea + [[0.85, 0.53]])
        #expect(transcript.knownSplit(of: "speaker-1", profiles: Self.profiles)?.moved == [4, 5, 6, 7])
    }

    @Test("a tie goes to whoever spoke first")
    func tie() {
        let transcript = Self.transcript(Self.bea + Self.ana.prefix(3))
        #expect(transcript.knownSplit(of: "speaker-1", profiles: Self.profiles) == KnownSplit(kept: "bea", other: "ana", moved: [3, 4, 5]))
    }

    @Test("one known person, or a second with a single sentence, is no split")
    func notEnough() {
        #expect(Self.transcript(Self.ana).knownSplit(of: "speaker-1", profiles: Self.profiles) == nil)
        #expect(Self.transcript(Self.ana + [Self.bea[0]]).knownSplit(of: "speaker-1", profiles: Self.profiles) == nil)
        #expect(Self.transcript(Self.ana + Self.bea).knownSplit(of: "speaker-1", profiles: ["ana": Self.profiles["ana"]!]) == nil)
    }

    @Test("sentences without a print and other voices stay where they are")
    func untouched() {
        var transcript = Self.transcript(Self.ana + Self.bea + [nil])
        transcript.segments.append(TranscriptSegment(channel: .others, start: 40, end: 42, text: "…", speaker: "speaker-2",
                                                     voiceprint: Voiceprint(Self.bea[0])))
        #expect(transcript.knownSplit(of: "speaker-1", profiles: Self.profiles)?.moved == [4, 5, 6])
    }
}
