import AVFAudio
import Foundation
import Testing

@testable import ListenKit

/// A sentence measured while it was heard is found again once voices are assigned, and
/// only when it is the same stretch of audio (EFFICIENCY.md E1).
@Suite("Sentence prints")
struct SentencePrintsTests {
    private let heard = TranscriptSegment(
        channel: .others, start: 10, end: 14.5, text: "Lo vemos el jueves.",
        words: [
            TimedWord(text: "Lo", start: 10.2, end: 10.4),
            TimedWord(text: " vemos", start: 10.4, end: 11),
            TimedWord(text: " el", start: 11, end: 11.2),
            TimedWord(text: " jueves.", start: 11.2, end: 12.1),
        ])

    @Test("a sentence one person said keeps, after separation, the times it was measured on")
    func wholeSentenceIsFound() throws {
        let span = SentencePrints.span(of: heard)
        var prints = SentencePrints()
        prints.keep(Voiceprint([1, 0]), from: span.start, to: span.end)

        let transcript = Transcript(startedAt: Date(), locale: "es_ES", source: "teams", segments: [heard])
            .assigningSpeakers([SpeakerTurn(speaker: "speaker-1", start: 9, end: 13)], renumbering: false)
        let segment = try #require(transcript.segments.first)
        #expect(transcript.segments.count == 1)
        #expect(prints.print(from: segment.start, to: segment.end) == Voiceprint([1, 0]))
    }

    @Test("a sentence split between two people is not found: its halves are new audio")
    func splitSentenceIsMeasuredAgain() {
        let span = SentencePrints.span(of: heard)
        var prints = SentencePrints()
        prints.keep(Voiceprint([1, 0]), from: span.start, to: span.end)

        let transcript = Transcript(startedAt: Date(), locale: "es_ES", source: "teams", segments: [heard])
            .assigningSpeakers([
                SpeakerTurn(speaker: "speaker-1", start: 9, end: 11),
                SpeakerTurn(speaker: "speaker-2", start: 11, end: 13),
            ], renumbering: false)
        #expect(transcript.segments.count == 2)
        #expect(transcript.segments.allSatisfy { prints.print(from: $0.start, to: $0.end) == nil })
    }

    @Test("a sentence without word times is measured on its whole range")
    func noWords() {
        let segment = TranscriptSegment(channel: .others, start: 3, end: 6, text: "Vale.")
        #expect(SentencePrints.span(of: segment) == (3, 6))
    }

    @Test("one sentence's audio is copied without the rest of the meeting")
    func accumulatorRange() throws {
        let accumulator = AudioAccumulator()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64_000))
        buffer.frameLength = 64_000
        let data = try #require(buffer.floatChannelData)
        for index in 0..<64_000 { data[0][index] = Float(index) / 64_000 }
        accumulator.append(buffer)

        let sentence = accumulator.copy(from: 1, to: 2.5)
        #expect(sentence.count == 24_000)
        // Kept as 16-bit samples: equal to within one step.
        #expect(abs((sentence.first ?? 0) - 0.25) < 1 / Float(Int16.max))
        // Past the end of what was heard: what there is, never a crash.
        #expect(accumulator.copy(from: 3.5, to: 9).count == 8_000)
        #expect(accumulator.copy(from: 9, to: 10).isEmpty)
    }
}
