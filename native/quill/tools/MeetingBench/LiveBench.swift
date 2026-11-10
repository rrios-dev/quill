import AVFAudio
import Foundation
import ListenKit
import SpeakerKit

/// `meeting-bench live <case> [--minutes N] [--fixed]` (EFFICIENCY.md E2): the live
/// diarization passes of a long meeting as the app runs them — the case's others track,
/// looped to N minutes, fed block by block into the app's `AudioAccumulator`, a pass
/// whenever `LivePassSchedule` says so on the meeting's own clock — then the final pass.
///
/// Reports the passes, the CPU they took, their share of the meeting and how much of each
/// pass's speech its stable label gives to the right person (the person the final pass
/// gives that label, as `incremental` scores it). `--fixed` runs the old two-minute
/// rhythm for comparison. Peak memory is read from outside (`/usr/bin/time -l`).
enum LiveBench {
    static func run(caseDirectory: URL, minutes: Double, fixed: Bool, models: URL) async throws {
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: caseDirectory.appendingPathComponent("reference.json")))
        let track = try Audio.load(caseDirectory.appendingPathComponent("others.wav"))
        let trackSeconds = Double(track.count) / Audio.sampleRate
        let total = minutes * 60
        // The reference repeats with the loop, so every pass is scored over all it heard.
        let refTurns = stride(from: 0.0, to: total, by: trackSeconds).flatMap { offset in
            reference.segments(of: "others").flatMap { segment in
                segment.spans.compactMap { span -> Metrics.Turn? in
                    let start = span.start + offset, end = min(span.end + offset, total)
                    return end > start ? Metrics.Turn(speaker: segment.speaker, start: start, end: end) : nil
                }
            }
        }

        let separator = SpeakerSeparator(modelsDirectory: models)
        try await separator.prepare()
        let accumulator = AudioAccumulator()
        let schedule = LivePassSchedule()
        let block = AVAudioFrameCount(Audio.sampleRate / 10)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Audio.format, frameCapacity: block) else { throw BenchError("alloc") }

        var labeler = SpeakerLabeler()
        var passes: [(at: Double, turns: [SpeakerTurn], seconds: Double)] = []
        var fed = 0.0
        var nextPass = Double(schedule.first.components.seconds)
        var position = 0
        let cpuBefore = cpuSeconds()
        var passCPU = 0.0

        func pass(at: Double) async throws {
            let cpu = cpuSeconds()
            let began = ContinuousClock.now
            let samples = accumulator.copy()
            let turns = labeler.label(SpeakerTurn.absorbingMinorVoices(try await separator.turns(for: samples)))
            let took = ContinuousClock.now - began
            passCPU += cpuSeconds() - cpu
            passes.append((at, turns, seconds(took)))
            nextPass = at + (fixed ? 120 : seconds(schedule.interval(after: took)))
        }

        // Counted in samples: summing tenths of a second never quite reaches `total`, and
        // the last block came out empty forever.
        let totalSamples = Int(total * Audio.sampleRate)
        var fedSamples = 0
        while fedSamples < totalSamples {
            let frames = min(Int(block), totalSamples - fedSamples)
            let data = buffer.floatChannelData![0]
            for index in 0..<frames {
                data[index] = track[position]
                position = (position + 1) % track.count
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            accumulator.append(buffer)
            fedSamples += frames
            fed = Double(fedSamples) / Audio.sampleRate
            if fed >= nextPass, fedSamples < totalSamples { try await pass(at: fed) }
        }
        try await pass(at: total)
        let totalCPU = cpuSeconds() - cpuBefore

        let final = passes.last!.turns.map { Metrics.Turn(speaker: $0.speaker, start: $0.start, end: $0.end) }
        let finalMapping = Metrics.mapping(reference: refTurns, hypothesis: final)
        for pass in passes {
            var right = 0.0, all = 0.0
            let shared = Metrics.sharedTime(pass.turns.map { Metrics.Turn(speaker: $0.speaker, start: $0.start, end: $0.end) }, refTurns)
            for (label, people) in shared {
                for (person, seconds) in people {
                    all += seconds
                    if finalMapping[label] == person { right += seconds }
                }
            }
            print(String(format: "pass at %5.0f s: %@ right; %d voices; took %.1f s",
                         pass.at, percent(all > 0 ? right / all : nil), Set(pass.turns.map(\.speaker)).count, pass.seconds))
        }
        let live = passes.dropLast()
        print(String(format: "%@ rhythm, %.0f min: %d live passes, %.0f s of pass CPU (%.1f %% of the meeting), final pass %.1f s, %.0f s CPU in all",
                     fixed ? "fixed" : "adaptive", minutes, live.count, passCPU,
                     passCPU / total * 100, passes.last!.seconds, totalCPU))
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// User and system CPU of this process so far.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}
