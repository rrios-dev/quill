import AVFAudio
import Foundation
import Speech
import Testing
@testable import ListenKit

/// Two channels transcribed at once, fed at the pace a capture delivers, not as fast as
/// files load: what a meeting does and the offline bench does not. Opt-in
/// (`QUILL_LIVE_SPEECH=1`): it needs the Spanish model and takes as long as the audio.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["QUILL_LIVE_SPEECH"] != nil))
struct LiveTranscribersTests {
    // Spoken Spanish for the Spanish model; the system voices read it.
    static let othersLine = "Buenos dias equipo. Vamos a repasar el estado general. Revisamos fechas, presupuesto y riesgos con el cliente."
    static let meLine = "Hola, prueba de micro. Si lees esto el canal funciona bien."

    static func spoken(_ text: String, voice: String) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return buffer
    }

    /// Feeds `audio` in 4096-frame blocks, one block per block's duration, after `delay`.
    static func feed(_ transcriber: ChannelTranscriber, _ audio: AVAudioPCMBuffer, delay: Double, total: Double) async {
        let format = audio.format
        let block = AVAudioFrameCount(4096)
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block)!
        silence.frameLength = block
        let blockSeconds = Double(block) / format.sampleRate
        var offset: AVAudioFrameCount = 0
        var elapsed = 0.0
        while elapsed < total {
            let piece: AVAudioPCMBuffer
            if elapsed >= delay, offset < audio.frameLength {
                let count = min(block, audio.frameLength - offset)
                piece = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block)!
                piece.frameLength = count
                for channel in 0..<Int(format.channelCount) {
                    piece.floatChannelData![channel].update(from: audio.floatChannelData![channel] + Int(offset), count: Int(count))
                }
                offset += count
            } else {
                piece = silence
            }
            transcriber.append(piece)
            elapsed += blockSeconds
            try? await Task.sleep(for: .seconds(blockSeconds))
        }
    }

    @Test func bothChannelsTranscribeWhenFedTogetherInRealTime() async throws {
        let locale = try #require(await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "es_ES")))
        _ = try? await AssetInventory.reserve(locale: locale)
        let others = try Self.spoken(Self.othersLine, voice: "Eddy (Spanish (Spain))")
        let me = try Self.spoken(Self.meLine, voice: "Flo (Spanish (Spain))")
        let collected = Collected()
        let othersTranscriber = try await ChannelTranscriber(channel: .others, locale: locale)
        try await othersTranscriber.start { collected.add($0) }
        let meTranscriber = try await ChannelTranscriber(channel: .me, locale: locale)
        try await meTranscriber.start { collected.add($0) }
        async let a: Void = Self.feed(othersTranscriber, others, delay: 0, total: 14)
        async let b: Void = Self.feed(meTranscriber, me, delay: 4, total: 14)
        _ = await (a, b)
        await othersTranscriber.finish()
        await meTranscriber.finish()
        let segments = collected.segments
        for segment in segments { print("LIVE \(segment.channel.rawValue): \(segment.text)") }
        print("LIVE diag others: \(othersTranscriber.diagnostics) | me: \(meTranscriber.diagnostics)")
        #expect(segments.contains { $0.channel == .others })
        #expect(segments.contains { $0.channel == .me })
        _ = await AssetInventory.release(reservedLocale: locale)
    }
}

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [TranscriptSegment] = []
    func add(_ segment: TranscriptSegment) { lock.withLock { all.append(segment) } }
    var segments: [TranscriptSegment] { lock.withLock { all } }
}
