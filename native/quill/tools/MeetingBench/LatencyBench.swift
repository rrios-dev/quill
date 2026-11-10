import AVFAudio
import Foundation
import ListenKit
import Speech

/// `meeting-bench latency <case> [--seconds N]` (EFFICIENCY.md E5): how long after a word
/// is said it first shows. The case's others track is fed at the pace a meeting plays it,
/// once per reporting mode — finished sentences only (1.4.1), drafts, drafts with fast
/// results — and every word of the finished transcript is timed from the moment its
/// audio was fed to the first result, draft or final, that covered it.
///
/// `BENCH_REPORTING` (`volatile`, `fast`, comma-separated) sets the mode `run` uses, to
/// see whether a mode changes the words the transcript keeps.
enum LatencyBench {
    static func reporting() -> Set<SpeechTranscriber.ReportingOption> {
        let names = (ProcessInfo.processInfo.environment["BENCH_REPORTING"] ?? "").split(separator: ",")
        var options: Set<SpeechTranscriber.ReportingOption> = []
        if names.contains("volatile") { options.insert(.volatileResults) }
        if names.contains("fast") { options.insert(.fastResults) }
        return options
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        /// Wall-clock second (from the start of feeding) and the audio range of each result.
        private(set) var results: [(at: Double, start: Double, end: Double)] = []
        private(set) var finals: [TranscriptSegment] = []
        let origin = ContinuousClock.now

        func saw(start: Double, end: Double) {
            let at = LiveBench.seconds(ContinuousClock.now - origin)
            lock.withLock { results.append((at, start, end)) }
        }

        func final(_ segment: TranscriptSegment) {
            saw(start: segment.start, end: segment.end)
            lock.withLock { finals.append(segment) }
        }
    }

    static func run(caseDirectory: URL, seconds: Double) async throws {
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: caseDirectory.appendingPathComponent("reference.json")))
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: reference.locale)) else {
            throw BenchError("no speech model for \(reference.locale)")
        }
        _ = try? await AssetInventory.reserve(locale: locale)
        let track = Array(try Audio.load(caseDirectory.appendingPathComponent("others.wav")).prefix(Int(seconds * Audio.sampleRate)))
        let modes: [(String, Set<SpeechTranscriber.ReportingOption>)] = [
            ("finished sentences only", []),
            ("drafts", [.volatileResults]),
            ("drafts, fast", [.volatileResults, .fastResults]),
        ]
        for (name, options) in modes {
            let seen = Seen()
            let transcriber = try await ChannelTranscriber(channel: .others, locale: locale, reporting: options)
            try await transcriber.start({ seen.final($0) }, onDraft: { seen.saw(start: $0.start, end: $0.end) })
            // 100 ms blocks, each fed when the meeting would have played it.
            let block = Int(Audio.sampleRate / 10)
            for offset in stride(from: 0, to: track.count, by: block) {
                let count = min(block, track.count - offset)
                let due = Double(offset + count) / Audio.sampleRate
                let wait = due - LiveBench.seconds(ContinuousClock.now - seen.origin)
                if wait > 0 { try await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
                let buffer = AVAudioPCMBuffer(pcmFormat: Audio.format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                track.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + offset, count: count) }
                transcriber.append(buffer)
            }
            await transcriber.finish()

            var delays: [Double] = []
            let results = seen.results
            for word in seen.finals.flatMap(\.words) where word.end < seconds {
                let middle = (word.start + word.end) / 2
                guard let first = results.filter({ $0.start <= middle && $0.end >= middle }).map(\.at).min() else { continue }
                delays.append(first - word.end)
            }
            delays.sort()
            func percentile(_ p: Double) -> Double { delays.isEmpty ? .nan : delays[min(delays.count - 1, Int(Double(delays.count) * p))] }
            let words = seen.finals.map(\.text).joined(separator: " ")
            print(String(format: "%@: %d words; first shown after the word ends: p50 %.2f s, p90 %.2f s; %d results",
                         name, delays.count, percentile(0.5), percentile(0.9), results.count))
            if ProcessInfo.processInfo.environment["BENCH_TEXT"] != nil { print("  \(words)") }
        }
        _ = await AssetInventory.release(reservedLocale: locale)
    }
}
