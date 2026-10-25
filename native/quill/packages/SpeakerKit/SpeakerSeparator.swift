import FluidAudio
import Foundation
import ListenKit

/// Tells the other people in a meeting apart, on the device.
///
/// macOS has no diarization of its own (checked in the macOS 27 SDK: `Speech` offers
/// transcribers and speech detection, nothing about who speaks), so this is the one
/// place Quill uses a third-party model: FluidAudio's offline pipeline (pyannote
/// community-1 segmentation and embeddings, VBx clustering) on the Neural Engine.
///
/// Offline on purpose: its own benchmarks put the streaming variants "substantially
/// worse", and a meeting summary is read after the meeting anyway.
public final class SpeakerSeparator: @unchecked Sendable {
    private let manager: OfflineDiarizerManager
    private let modelsDirectory: URL

    /// - Parameters:
    ///   - expectedSpeakers: when the user knows how many others were in the call,
    ///     telling the clustering removes its most common mistake (merging or splitting
    ///     voices). Nil lets it decide.
    ///   - mergeDistance: the clustering's cut, the distance under which two voiceprints
    ///     are one person (FluidAudio's `clustering.threshold`; larger merges more).
    ///     Nil keeps the library's default.
    ///   - tuning: experiment-only overrides of VBx's `warmStartFa` / `warmStartFb`, for the bench.
    public init(modelsDirectory: URL, expectedSpeakers: Int? = nil, mergeDistance: Double? = nil,
                tuning: (fa: Double?, fb: Double?) = (nil, nil)) {
        var config = OfflineDiarizerConfig.default
        if let expectedSpeakers {
            config.clustering.numSpeakers = expectedSpeakers
        }
        if let mergeDistance {
            config.clustering.threshold = mergeDistance
        }
        if let fa = tuning.fa { config.clustering.warmStartFa = fa }
        if let fb = tuning.fb { config.clustering.warmStartFb = fb }
        manager = OfflineDiarizerManager(config: config)
        self.modelsDirectory = modelsDirectory
    }

    /// Loads the models, downloading them the first time.
    public func prepare() async throws {
        try await manager.prepareModels(directory: modelsDirectory)
    }

    /// Speaker turns for 16 kHz mono samples (`AudioAccumulator`).
    public func turns(for samples: [Float]) async throws -> [SpeakerTurn] {
        try await separate(samples).turns
    }

    /// Turns and each voice's average embedding (its "voiceprint"), for deciding what
    /// a voice that barely speaks really is.
    public func separate(_ samples: [Float]) async throws -> (turns: [SpeakerTurn], voiceprints: [String: [Float]]) {
        let result = try await manager.process(audio: samples)
        let turns = result.segments.map {
            SpeakerTurn(
                speaker: $0.speakerId,
                start: Double($0.startTimeSeconds),
                end: Double($0.endTimeSeconds)
            )
        }
        return (turns, result.speakerDatabase ?? [:])
    }
}
