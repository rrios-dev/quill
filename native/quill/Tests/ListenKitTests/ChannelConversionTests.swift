import AVFAudio
import Testing
@testable import ListenKit

struct ChannelConversionTests {
    /// Voice processing hands the microphone over as three channels at 16 kHz (measured
    /// 2026-10-30); the model takes one. A tone on every channel must survive the trip.
    @Test func threeChannelVoiceProcessingInputKeepsItsSignal() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))
        let source = AVAudioFormat(standardFormatWithSampleRate: 16_000, channelLayout: layout)
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4096))
        buffer.frameLength = 4096
        for channel in 0..<3 {
            for frame in 0..<4096 { buffer.floatChannelData![channel][frame] = 0.3 * sin(Float(frame) * 0.1) }
        }
        let converter = try #require(ChannelTranscriber.converter(from: source, to: target))
        let output = try #require(ChannelTranscriber.convert(buffer, with: converter, to: target))
        let peak = (0..<Int(output.frameLength)).map { abs(Int(output.int16ChannelData![0][$0])) }.max() ?? 0
        print("CONVERT peak=\(peak) frames=\(output.frameLength)")
        #expect(peak > 1_000)
    }
}
