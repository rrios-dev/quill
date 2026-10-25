import AVFAudio
import Foundation
import ListenKit
import SpeakerKit
import Speech

/// Runs one case through the same code a meeting goes through in Quill — the
/// `ChannelTranscriber` of each channel, the `AudioAccumulator`, the `SpeakerSeparator`
/// and `Transcript.assigningSpeakers` — and scores the result against the reference.
///
/// Offline: the audio comes from a file instead of a device, fed in the blocks a device
/// would deliver. What it does not cover (the capture itself) is tier T3.
enum Pipeline {
    struct Report: Codable {
        var name: String
        var date: Date
        var audioSeconds: Double
        var processingSeconds: Double
        var othersWER: Double?
        var meWER: Double?
        var diarization: Metrics.Diarization?
        /// People who came out as one voice (`Metrics.merged`).
        var merged: [[String]]?
        /// Of the words transcribed right, how many went to the right person.
        var attribution: Double?
        /// Of the words transcribed right, how many are placed within half a second of
        /// the sentence they belong to.
        var timing: Double?
        /// T4: share of the words heard on the microphone that the owner did not read.
        var meLeak: Double?
        var referenceWords: [String: Int]
        var notes: [String]
    }

    static func run(caseDirectory: URL, models: URL) async throws -> (Report, Transcript, [Metrics.Turn]) {
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: caseDirectory.appendingPathComponent("reference.json")))
        let began = Date()
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: reference.locale)) else {
            throw BenchError("no speech model for \(reference.locale)")
        }
        _ = try? await AssetInventory.reserve(locale: locale)
        defer { Task { _ = await AssetInventory.release(reservedLocale: locale) } }
        // Without the language's model the case still scores the voice separation; the
        // report says the words were not measured.
        let transcribes = await AssetInventory.status(forModules: [SpeechTranscriber(locale: locale, preset: .transcription)]) == .installed

        let collected = SegmentBox()
        var othersSamples: [Float] = []
        var audioSeconds = 0.0
        // Both channels at once, as in a meeting: two transcribers share the device.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (channelName, file) in reference.audio {
                let channel: Channel = channelName == "me" ? .me : .others
                let samples = try Audio.load(caseDirectory.appendingPathComponent(file))
                audioSeconds = max(audioSeconds, Double(samples.count) / Audio.sampleRate)
                if channel == .others { othersSamples = samples }
                guard transcribes else { continue }
                group.addTask {
                    let transcriber = try await ChannelTranscriber(channel: channel, locale: locale)
                    try await transcriber.start { collected.append($0) }
                    // The blocks a 48 kHz device delivers, resampled: 4096 frames at a time.
                    let block = 4096
                    for offset in stride(from: 0, to: samples.count, by: block) {
                        let count = min(block, samples.count - offset)
                        let buffer = AVAudioPCMBuffer(pcmFormat: Audio.format, frameCapacity: AVAudioFrameCount(count))!
                        buffer.frameLength = AVAudioFrameCount(count)
                        samples.withUnsafeBufferPointer {
                            buffer.floatChannelData![0].update(from: $0.baseAddress! + offset, count: count)
                        }
                        transcriber.append(buffer)
                    }
                    await transcriber.finish()
                }
            }
            try await group.waitForAll()
        }

        let raw = Transcript(startedAt: Date(), locale: reference.locale, source: reference.name, segments: collected.segments)
        var transcript = raw
        var turns: [SpeakerTurn] = []
        let notes: [String] = transcribes ? [] : ["the speech model for \(locale.identifier) is not installed: words not measured"]
        if !othersSamples.isEmpty {
            // BENCH_MERGE_DISTANCE: try another clustering cut without touching the product.
            let environment = ProcessInfo.processInfo.environment
            let separator = SpeakerSeparator(
                modelsDirectory: models,
                expectedSpeakers: environment["BENCH_SPEAKERS"].flatMap(Int.init),
                mergeDistance: environment["BENCH_MERGE_DISTANCE"].flatMap(Double.init),
                tuning: (environment["BENCH_FA"].flatMap(Double.init), environment["BENCH_FB"].flatMap(Double.init)))
            try await separator.prepare()
            let separated = try await separator.separate(othersSamples)
            turns = ProcessInfo.processInfo.environment["BENCH_RAW_VOICES"] != nil
                ? separated.turns : SpeakerTurn.absorbingMinorVoices(separated.turns)
            if ProcessInfo.processInfo.environment["BENCH_VOICEPRINTS"] != nil {
                Self.printVoiceprints(turns: turns, voiceprints: separated.voiceprints)
            }
            transcript = raw.assigningSpeakers(turns)
        }

        var report = score(reference: reference, raw: raw, transcript: transcript, turns: turns, transcribes: transcribes)
        report.audioSeconds = audioSeconds
        report.processingSeconds = Date().timeIntervalSince(began)
        report.notes += notes
        return (report, transcript, turns.map { Metrics.Turn(speaker: $0.speaker, start: $0.start, end: $0.end) })
    }

    /// Scores a transcript against the reference: the offline run's and the live capture's
    /// (T3) alike.
    static func score(reference: Reference, raw: Transcript, transcript: Transcript, turns: [SpeakerTurn],
                      transcribes: Bool) -> Report {
        // Words per channel, in speaking order.
        func referenceWords(_ channel: String) -> [(word: String, speaker: String, start: Double, end: Double)] {
            reference.segments(of: channel).flatMap { segment in
                Metrics.words(segment.text).map { ($0, segment.speaker, segment.start, segment.end) }
            }
        }
        func hypothesisWords(_ channel: Channel, in transcript: Transcript) -> [(word: String, speaker: String)] {
            transcript.ordered.filter { $0.channel == channel }.flatMap { segment in
                Metrics.words(segment.text).map { ($0, segment.speaker ?? segment.channel.rawValue) }
            }
        }

        var report = Report(name: reference.name, date: Date(), audioSeconds: reference.duration,
                            processingSeconds: 0, referenceWords: [:], notes: [])
        for channelName in reference.audio.keys {
            let channel: Channel = channelName == "me" ? .me : .others
            let ref = referenceWords(channelName)
            let hyp = hypothesisWords(channel, in: transcript)
            report.referenceWords[channelName] = ref.count
            let edits = Metrics.align(ref.map(\.word), hyp.map(\.word))
            let wer = Metrics.wer(edits, referenceCount: ref.count)
            if transcribes {
                if channel == .me { report.meWER = wer } else { report.othersWER = wer }
            }

            if channel == .others, !turns.isEmpty {
                let refTurns = reference.segments(of: "others").flatMap { segment in
                    segment.spans.map { Metrics.Turn(speaker: segment.speaker, start: $0.start, end: $0.end) }
                }
                let hypTurns = turns.map { Metrics.Turn(speaker: $0.speaker, start: $0.start, end: $0.end) }
                let rawMapping = Metrics.mapping(reference: refTurns, hypothesis: hypTurns)
                report.diarization = Metrics.diarization(reference: refTurns, hypothesis: hypTurns, mapping: rawMapping)
                report.merged = Metrics.merged(reference: refTurns, hypothesis: hypTurns)
                // Transcript labels are renumbered ("speaker-1"…) by assigningSpeakers, so
                // map them on their own segments' times.
                let labelled = transcript.segments.filter { $0.channel == .others && $0.speaker != nil }
                    .map { Metrics.Turn(speaker: $0.speaker!, start: $0.start, end: $0.end) }
                let mapping = Metrics.mapping(reference: refTurns, hypothesis: labelled)
                var right = 0, matched = 0
                for edit in edits {
                    if case .match(let r, let h) = edit {
                        matched += 1
                        if mapping[hyp[h].speaker] == ref[r].speaker { right += 1 }
                    }
                }
                report.attribution = transcribes && matched > 0 ? Double(right) / Double(matched) : nil
            }

            // Timing, on the words the model timed (before diarization consumes them).
            let timed = raw.ordered.filter { $0.channel == channel }.flatMap { segment in
                segment.words.flatMap { word in Metrics.words(word.text).map { ($0, word.start) } }
            }
            if !timed.isEmpty {
                let timedEdits = Metrics.align(ref.map(\.word), timed.map(\.0))
                var inside = 0, matched = 0
                for edit in timedEdits {
                    if case .match(let r, let h) = edit {
                        matched += 1
                        if timed[h].1 >= ref[r].start - 0.5, timed[h].1 <= ref[r].end + 0.5 { inside += 1 }
                    }
                }
                let share = matched > 0 ? Double(inside) / Double(matched) : 0
                report.timing = min(report.timing ?? 1, share)
            } else if transcribes {
                report.notes.append("\(channelName): the model returned no word timings")
            }
        }
        return report
    }

    /// A live capture starts a moment after the audio does: hypothesis times are shifted
    /// by the offset that best lines the voices up with the reference, searched in 50 ms
    /// steps, and the offset is reported.
    static func bestOffset(reference: Reference, turns: [SpeakerTurn], range: ClosedRange<Double>) -> Double {
        let refTurns = reference.segments(of: "others").flatMap { segment in
            segment.spans.map { Metrics.Turn(speaker: segment.speaker, start: $0.start, end: $0.end) }
        }
        var best = (offset: 0.0, der: Double.infinity)
        for offset in stride(from: range.lowerBound, through: range.upperBound, by: 0.05) {
            let shifted = turns.map { Metrics.Turn(speaker: $0.speaker, start: $0.start + offset, end: $0.end + offset) }
            let der = Metrics.diarization(reference: refTurns, hypothesis: shifted,
                                          mapping: Metrics.mapping(reference: refTurns, hypothesis: shifted)).der
            if der < best.der { best = (offset, der) }
        }
        return best.offset
    }

    static func shifted(_ transcript: Transcript, by offset: Double) -> Transcript {
        var copy = transcript
        copy.segments = transcript.segments.map { segment in
            var moved = segment
            moved.start += offset
            moved.end += offset
            moved.words = segment.words.map { TimedWord(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
            return moved
        }
        return copy
    }

}

extension Pipeline {
    /// Experiment output: each voice's speaking time and its closest other voice.
    static func printVoiceprints(turns: [SpeakerTurn], voiceprints: [String: [Float]]) {
        var seconds: [String: Double] = [:]
        for turn in turns { seconds[turn.speaker, default: 0] += turn.end - turn.start }
        func cosine(_ a: [Float], _ b: [Float]) -> Float {
            let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
            let na = a.reduce(0) { $0 + $1 * $1 }.squareRoot(), nb = b.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return dot / max(na * nb, 1e-9)
        }
        for speaker in seconds.keys.sorted() {
            guard let print0 = voiceprints[speaker] else { continue }
            let others = voiceprints.filter { $0.key != speaker }.map { ($0.key, cosine(print0, $0.value)) }.sorted { $0.1 > $1.1 }
            print("voiceprint \(speaker) \(String(format: "%.1f", seconds[speaker]!)) s → " +
                  others.prefix(3).map { "\($0.0) \(String(format: "%.2f", $0.1))" }.joined(separator: ", "))
        }
    }
}

/// Segments arrive from the transcribers' own tasks.
final class SegmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TranscriptSegment] = []
    func append(_ segment: TranscriptSegment) { lock.withLock { stored.append(segment) } }
    var segments: [TranscriptSegment] { lock.withLock { stored } }
}
