import Foundation
import Testing

@testable import ListenKit

/// Moving sentences between voices, and what is proposed to follow them.
@Suite("Voice correction")
struct VoiceCorrectionTests {
    static func segment(_ speaker: String?, _ print: [Float]?, channel: Channel = .others, at start: Double = 0) -> TranscriptSegment {
        TranscriptSegment(channel: channel, start: start, end: start + 2, text: "…", speaker: speaker,
                          voiceprint: print.map(Voiceprint.init))
    }

    @Test("a new voice takes the next number, past the names already given")
    func newLabel() {
        var transcript = Transcript(startedAt: Date(), locale: "es_ES", source: "t",
                                    segments: [Self.segment("speaker-1", nil), Self.segment("speaker-3", nil)])
        #expect(transcript.newVoiceLabel == "speaker-4")
        transcript.names["speaker-7"] = "Ana"
        #expect(transcript.newVoiceLabel == "speaker-8")
    }

    @Test("moving touches only the others' segments")
    func moveOthersOnly() {
        var transcript = Transcript(startedAt: Date(), locale: "es_ES", source: "t", segments: [
            Self.segment("speaker-1", nil), Self.segment(nil, nil, channel: .me),
        ])
        transcript.move([0, 1], to: "speaker-2")
        #expect(transcript.segments.map(\.speaker) == ["speaker-2", nil])
    }

    @Test("one mark proposes nothing; two marks propose the sentences that sound like them")
    func proposal() {
        let a: [[Float]] = [[1, 0.05], [0.98, 0.12], [1, -0.02]]
        let b: [[Float]] = [[0.8, 0.6], [0.75, 0.62], [0.82, 0.55], [0.7, 0.7]]
        var transcript = Transcript(startedAt: Date(), locale: "es_ES", source: "t",
                                    segments: (a + b).map { Self.segment("speaker-1", $0) })
        transcript.move([3], to: "speaker-2")
        #expect(transcript.soundingLike("speaker-2", from: "speaker-1").isEmpty)
        transcript.move([4], to: "speaker-2")
        #expect(transcript.soundingLike("speaker-2", from: "speaker-1") == [5, 6])
    }

    @Test("a voiceprint survives a round trip as base64, and old segments decode without one")
    func coding() throws {
        let segment = Self.segment("speaker-1", [0.25, -1.5, 3])
        let data = try JSONEncoder().encode(segment)
        #expect(String(decoding: data, as: UTF8.self).contains("\"voiceprint\":\""))
        #expect(try JSONDecoder().decode(TranscriptSegment.self, from: data) == segment)
        let old = #"{"channel":"others","start":0,"end":1,"text":"hola","words":[]}"#
        #expect(try JSONDecoder().decode(TranscriptSegment.self, from: Data(old.utf8)).voiceprint == nil)
    }
}
