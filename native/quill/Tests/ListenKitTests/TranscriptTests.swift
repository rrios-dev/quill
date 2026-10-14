import AVFAudio
import Foundation
import Testing

@testable import ListenKit

/// What the synthesis reads (`rendered()`) and what keeps the channels aligned after a
/// capture comes back (`padSilence`).
@Suite("Transcript and alignment")
struct TranscriptTests {
    @Test("two channels finishing out of order are read in speaking order, turns merged")
    func renderedInSpeakingOrder() {
        // The microphone finished its segment later than the others' channel did.
        let transcript = Transcript(startedAt: Date(), locale: "es_ES", source: "teams", segments: [
            TranscriptSegment(channel: .others, start: 4, end: 6, text: "¿Lo ves?", speaker: "speaker-1"),
            TranscriptSegment(channel: .others, start: 6.5, end: 8, text: "Es el sábado.", speaker: "speaker-1"),
            TranscriptSegment(channel: .me, start: 0, end: 3, text: "Empezamos."),
        ], names: ["me": "Roberto", "speaker-1": "Lucía"])
        #expect(transcript.rendered() == "[00:00:00] Roberto: Empezamos.\n[00:00:04] Lucía: ¿Lo ves? Es el sábado.")
    }

    @Test("padding fills a gap with silence so later audio keeps its time")
    func accumulatorPadding() throws {
        let accumulator = AudioAccumulator()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let second = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        second.frameLength = 48_000
        accumulator.append(second)
        // The capture died for two seconds and came back at 3 s.
        accumulator.padSilence(upTo: 3)
        accumulator.append(second)
        #expect(abs(accumulator.seconds - 4) < 0.01)
    }

    @Test("a gap under half a second is jitter, not a loss: nothing is padded")
    func smallGapsAreIgnored() throws {
        let accumulator = AudioAccumulator()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let second = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        second.frameLength = 16_000
        accumulator.append(second)
        accumulator.padSilence(upTo: 1.3)
        #expect(abs(accumulator.seconds - 1) < 0.01)
    }
}
