import FluidAudio
import Foundation
import ListenKit

/// One voiceprint for one stretch of a single voice, with FluidAudio's streaming
/// embedding model (WeSpeaker), without running the whole diarization pipeline on it.
///
/// Used for splitting a voice, not for finding the voices: measured on the bench
/// (VOICES.md S1), its voiceprints told the most alike pair apart sentence by sentence
/// (100 %, blind) where the offline pipeline's did no better than chance (56 %).
public final class SpeakerEmbedder: @unchecked Sendable {
    private let manager = DiarizerManager()
    private let modelsDirectory: URL

    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    /// Loads the models, downloading them the first time.
    public func prepare() async throws {
        manager.initialize(models: try await DiarizerModels.downloadIfNeeded(to: modelsDirectory))
    }

    /// L2-normalised voiceprint of 16 kHz mono samples.
    public func voiceprint(of samples: [Float]) throws -> [Float] {
        try manager.extractSpeakerEmbedding(from: samples)
    }

    /// Measures each of the others' segments on its own, for splitting a voice later
    /// (`Transcript.soundingLike`). The audio is not kept after the meeting, so this is
    /// the only moment it can be done. Segments under `minimumSeconds` are left
    /// unmeasured: their voiceprint would be noise.
    public func measuringSegments(of transcript: Transcript, samples: [Float], minimumSeconds: Double = 1) -> Transcript {
        var result = transcript
        let rate = AudioAccumulator.sampleRate
        for index in result.segments.indices {
            let segment = result.segments[index]
            guard segment.channel == .others, segment.end - segment.start >= minimumSeconds else { continue }
            let first = max(0, Int(segment.start * rate)), last = min(samples.count, Int(segment.end * rate))
            guard last - first >= Int(minimumSeconds * rate),
                  let print = try? voiceprint(of: Array(samples[first..<last])) else { continue }
            result.segments[index].voiceprint = Voiceprint(print)
        }
        return result
    }
}
