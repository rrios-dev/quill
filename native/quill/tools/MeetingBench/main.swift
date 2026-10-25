import Foundation
import ListenKit
import SpeakerKit

// meeting-bench: transcription and voice separation measured on meetings with a known
// answer (docs/initiatives/quill/TESTING-MEETINGS.md, tier T2).
//
//   meeting-bench prepare            compose C2 from the OpenSLR clips, prepare C3 (AMI),
//                                    compose C4 from the most alike voices of the pool
//   meeting-bench run [case…]        run cases, print and save their reports
//   meeting-bench run --gate [case…] also fail when a case is worse than gate.json
//
// The corpus lives in ~/Library/Caches/QuillMeetingBench (fetch_corpus.py, fetch_ami.py),
// outside the repo: it is other people's voices under their own licences.

let arguments = Array(CommandLine.arguments.dropFirst())
let cache = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/QuillMeetingBench")
let gateFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("gate.json")

/// The diarizer models Quill already downloaded, copied once so the bench never
/// downloads them itself.
func modelsDirectory() throws -> URL {
    let models = cache.appendingPathComponent("models")
    let installed = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/dev.rrios.quill/meetings-data/models")
    if !FileManager.default.fileExists(atPath: models.path), FileManager.default.fileExists(atPath: installed.path) {
        try FileManager.default.copyItem(at: installed, to: models)
    }
    return models
}

func percent(_ value: Double?) -> String {
    value.map { String(format: "%.1f %%", $0 * 100) } ?? "—"
}

struct Gate: Decodable {
    struct Limits: Decodable {
        var othersWER: Double?
        var meWER: Double?
        var der: Double?
        var attribution: Double?
        var timing: Double?
        var speakerCount: Bool?
        /// Most people allowed to come out as one voice, summed over merged groups.
        var merged: Int?
    }
    var cases: [String: Limits]
}

func check(_ report: Pipeline.Report, against limits: Gate.Limits) -> [String] {
    var failures: [String] = []
    if let limit = limits.othersWER, let value = report.othersWER, value > limit {
        failures.append("others WER \(percent(value)) > \(percent(limit))")
    }
    if let limit = limits.meWER, let value = report.meWER, value > limit {
        failures.append("me WER \(percent(value)) > \(percent(limit))")
    }
    if let limit = limits.der, let value = report.diarization?.der, value > limit {
        failures.append("DER \(percent(value)) > \(percent(limit))")
    }
    if let limit = limits.attribution, let value = report.attribution, value < limit {
        failures.append("attribution \(percent(value)) < \(percent(limit))")
    }
    if let limit = limits.timing, let value = report.timing, value < limit {
        failures.append("timing \(percent(value)) < \(percent(limit))")
    }
    if limits.speakerCount == true, let d = report.diarization, d.hypothesisSpeakers != d.referenceSpeakers {
        failures.append("found \(d.hypothesisSpeakers) voices, there were \(d.referenceSpeakers)")
    }
    if let limit = limits.merged, let groups = report.merged, groups.map(\.count).reduce(0, +) > limit {
        failures.append("\(groups.map(\.count).reduce(0, +)) people sharing a voice > \(limit)")
    }
    if limits.diarizationRequired, report.diarization == nil {
        failures.append("no diarization")
    }
    return failures
}

extension Gate.Limits {
    var diarizationRequired: Bool { der != nil }
}

do {
    switch arguments.first {
    case "prepare":
        for directory in try Composer.compose(cache: cache) { print("composed \(directory.lastPathComponent)") }
        print("prepared \(try AMICase.prepare(cache: cache).lastPathComponent)")
        print("composed \(try await SimilarVoices.compose(cache: cache, models: try modelsDirectory()).lastPathComponent)")
    case "run":
        let gating = arguments.contains("--gate")
        var names = Array(arguments.dropFirst().filter { !$0.hasPrefix("--") })
        if names.isEmpty {
            names = try FileManager.default.contentsOfDirectory(atPath: cache.appendingPathComponent("cases").path).sorted()
        }
        let gate = gating ? try JSONDecoder().decode(Gate.self, from: Data(contentsOf: gateFile)) : nil
        let models = try modelsDirectory()
        var failed = false
        for name in names {
            let directory = cache.appendingPathComponent("cases/\(name)")
            let (report, transcript, turns) = try await Pipeline.run(caseDirectory: directory, models: models)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let reports = directory.appendingPathComponent("reports")
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: report.date).replacingOccurrences(of: ":", with: "-")
            try encoder.encode(report).write(to: reports.appendingPathComponent("\(stamp).json"))
            try encoder.encode(turns).write(to: reports.appendingPathComponent("\(stamp).turns.json"))
            try transcript.rendered().write(to: reports.appendingPathComponent("\(stamp).transcript.txt"), atomically: true, encoding: .utf8)
            print("""
            ▸ \(name) — \(Int(report.audioSeconds)) s of audio in \(Int(report.processingSeconds)) s
              others WER \(percent(report.othersWER))  me WER \(percent(report.meWER))
              DER \(percent(report.diarization?.der)) (missed \(percent(report.diarization?.missed)), false alarm \(percent(report.diarization?.falseAlarm)), confusion \(percent(report.diarization?.confusion)))
              voices found \(report.diarization.map { "\($0.hypothesisSpeakers) of \($0.referenceSpeakers)" } ?? "—")  merged \(report.merged.map { $0.isEmpty ? "none" : $0.map { $0.joined(separator: "+") }.joined(separator: ", ") } ?? "—")
              words to the right person \(percent(report.attribution))  words at the right moment \(percent(report.timing))
            """)
            for note in report.notes { print("  note: \(note)") }
            if let limits = gate?.cases[name] {
                let failures = check(report, against: limits)
                if failures.isEmpty { print("  ✓ gate") } else {
                    failed = true
                    for failure in failures { print("  ✗ \(failure)") }
                }
            }
        }
        exit(failed ? 1 : 0)
    case "separability":
        // Can two voices be told apart sentence by sentence (VOICES.md S1)?
        guard arguments.count > 2 else { throw BenchError("separability <speaker> <speaker>") }
        try await SimilarVoices.separability(cache: cache, models: try modelsDirectory(), a: arguments[1], b: arguments[2])
    case "split":
        // S1 end to end: the case as Quill leaves it, each sentence measured, then the user
        // moving k sentences of the hidden person out of a merged voice and accepting
        // what Quill proposes. Scored on the merged voice's sentences: share that end up
        // with the right person.
        guard arguments.count > 1 else { throw BenchError("split <case>") }
        let directory = cache.appendingPathComponent("cases/\(arguments[1])")
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: directory.appendingPathComponent("reference.json")))
        let (_, transcript, _) = try await Pipeline.run(caseDirectory: directory, models: try modelsDirectory())
        let embedder = SpeakerEmbedder(modelsDirectory: try modelsDirectory().appendingPathComponent("streaming"))
        try await embedder.prepare()
        let samples = try Audio.load(directory.appendingPathComponent("others.wav"))
        let began = Date()
        let measured = embedder.measuringSegments(of: transcript, samples: samples)
        let others = measured.segments.indices.filter { measured.segments[$0].channel == .others }
        // `--export <file>`: the measured transcript, for opening it in a debug build.
        if let flag = arguments.firstIndex(of: "--export"), arguments.indices.contains(flag + 1) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            try encoder.encode(measured).write(to: URL(fileURLWithPath: arguments[flag + 1]))
        }
        print("measured \(others.filter { measured.segments[$0].voiceprint != nil }.count) of \(others.count) sentences in \(String(format: "%.1f", Date().timeIntervalSince(began))) s")
        let refTurns = reference.segments(of: "others").flatMap { segment in
            segment.spans.map { Metrics.Turn(speaker: segment.speaker, start: $0.start, end: $0.end) }
        }
        func truth(_ segment: TranscriptSegment) -> String? {
            var seconds: [String: Double] = [:]
            for turn in refTurns {
                let overlap = min(turn.end, segment.end) - max(turn.start, segment.start)
                if overlap > 0 { seconds[turn.speaker, default: 0] += overlap }
            }
            return seconds.max { $0.value < $1.value }?.key
        }
        // A merged voice: one label whose sentences belong to two people.
        for label in Set(others.compactMap { measured.segments[$0].speaker }).sorted() {
            let mine = others.filter { measured.segments[$0].speaker == label && measured.segments[$0].voiceprint != nil }
            var counts: [String: Int] = [:]
            for index in mine { if let who = truth(measured.segments[index]) { counts[who, default: 0] += 1 } }
            let people = counts.sorted { $0.value > $1.value }
            guard people.count >= 2, people[1].value >= 3 else { continue }
            let (kept, hidden) = (people[0].key, people[1].key)
            print("voice \(label): \(people.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
            for k in [1, 2, 3] {
                var corrected = measured
                let marks = mine.filter { truth(measured.segments[$0]) == hidden }.prefix(k)
                let newLabel = corrected.newVoiceLabel
                corrected.move(marks, to: newLabel)
                corrected.move(corrected.soundingLike(newLabel, from: label), to: newLabel)
                let rest = mine.filter { !marks.contains($0) }
                let right = rest.filter {
                    let who = truth(measured.segments[$0])
                    return (corrected.segments[$0].speaker == newLabel) == (who == hidden) && (who == hidden || who == kept)
                }.count
                print("  \(k) marked: \(percent(Double(right) / Double(max(rest.count, 1)))) of the other \(rest.count) sentences with the right person")
            }
        }
    case "incremental":
        // Live naming: diarization passes over what was heard so far, every two minutes,
        // labelled by SpeakerLabeler; then the final pass. Scored as the share of each
        // pass's speech whose stable label points at the right person — the person the
        // final pass gives that label. A name given at minute 2 must still be right at
        // the end.
        guard arguments.count > 1 else { throw BenchError("incremental <case>") }
        let directory = cache.appendingPathComponent("cases/\(arguments[1])")
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: directory.appendingPathComponent("reference.json")))
        let samples = try Audio.load(directory.appendingPathComponent("others.wav"))
        let separator = SpeakerSeparator(modelsDirectory: try modelsDirectory())
        try await separator.prepare()
        let refTurns = reference.segments(of: "others").flatMap { segment in
            segment.spans.map { Metrics.Turn(speaker: segment.speaker, start: $0.start, end: $0.end) }
        }
        var labeler = SpeakerLabeler()
        var passes: [(at: Double, turns: [SpeakerTurn], seconds: Double)] = []
        let total = Double(samples.count) / Audio.sampleRate
        for at in Array(stride(from: 120.0, to: total - 1, by: 120)) + [total] {
            let began = Date()
            let prefix = Array(samples[0..<min(samples.count, Int(at * Audio.sampleRate))])
            let turns = labeler.label(SpeakerTurn.absorbingMinorVoices(try await separator.turns(for: prefix)))
            passes.append((at, turns, Date().timeIntervalSince(began)))
        }
        let final = passes.last!.turns.map { Metrics.Turn(speaker: $0.speaker, start: $0.start, end: $0.end) }
        let finalMapping = Metrics.mapping(reference: refTurns, hypothesis: final)
        for pass in passes {
            var right = 0.0, all = 0.0
            for turn in pass.turns {
                for ref in refTurns where ref.end > turn.start && ref.start < turn.end {
                    let overlap = min(ref.end, turn.end) - max(ref.start, turn.start)
                    all += overlap
                    if finalMapping[turn.speaker] == ref.speaker { right += overlap }
                }
            }
            let labels = Set(pass.turns.map(\.speaker)).sorted()
            if ProcessInfo.processInfo.environment["BENCH_LABELS"] != nil {
                for label in labels {
                    var who: [String: Double] = [:]
                    for turn in pass.turns where turn.speaker == label {
                        for ref in refTurns where ref.end > turn.start && ref.start < turn.end {
                            who[ref.speaker, default: 0] += min(ref.end, turn.end) - max(ref.start, turn.start)
                        }
                    }
                    print("    \(label): " + who.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \(Int($0.value)) s" }.joined(separator: ", "))
                }
            }
            print(String(format: "pass at %4.0f s: %@ right; voices %@; took %.1f s",
                         pass.at, percent(all > 0 ? right / all : nil), labels.joined(separator: " "), pass.seconds))
        }
    case "live-audio":
        // The case's others track with three seconds of silence in front, for T3: the
        // capture starts a moment after the player does, and must not miss the first words.
        guard arguments.count > 1 else { throw BenchError("live-audio <case>") }
        let directory = cache.appendingPathComponent("cases/\(arguments[1])")
        let samples = try Audio.load(directory.appendingPathComponent("others.wav"))
        let live = directory.appendingPathComponent("others-live.wav")
        try Audio.write([Float](repeating: 0, count: Int(Audio.sampleRate * 3)) + samples, to: live)
        print(live.path)
    case "score":
        // T3: score what the live capture produced (ListenProbe's report files).
        guard arguments.count > 2 else { throw BenchError("score <case> <probe report path> [--gate]") }
        let directory = cache.appendingPathComponent("cases/\(arguments[1])")
        let base = arguments[2]
        var reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: directory.appendingPathComponent("reference.json")))
        let probeText = (try? String(contentsOfFile: base, encoding: .utf8)) ?? ""
        let captured = probeText.split(separator: "\n").first { $0.hasPrefix("LISTEN captured others=") }
            .flatMap { Double($0.dropFirst("LISTEN captured others=".count).dropLast(2)) }
        let raw = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: URL(fileURLWithPath: base + ".raw.json")))
        let assigned = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: URL(fileURLWithPath: base + ".json")))
        struct Row: Decodable { var speaker: String; var start: Double; var end: Double }
        let rows = (try? JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: base + ".turns.json")))) ?? []
        // The product's current rule, so a capture made before a change can be rescored.
        let turns = SpeakerTurn.absorbingMinorVoices(rows.map { SpeakerTurn(speaker: $0.speaker, start: $0.start, end: $0.end) })
        // Only the channels the capture listened to are scored (T3 has no microphone).
        if !probeText.contains("LISTEN captured me=") { reference.audio.removeValue(forKey: "me") }
        // Hypothesis time t is reference time t + offset; the lead silence makes it negative.
        // A shorter listen (T4) is scored on the part of the meeting it heard.
        if let captured, captured < reference.duration {
            let probeOffset = Pipeline.bestOffset(reference: reference, turns: turns, range: -6...1)
            reference.segments = reference.segments.filter { $0.end <= captured + probeOffset }
            reference.duration = captured + probeOffset
        }
        let offset = Pipeline.bestOffset(reference: reference, turns: turns, range: -6...1)
        let shiftedTurns = turns.map { SpeakerTurn(speaker: $0.speaker, start: $0.start + offset, end: $0.end + offset) }
        var report = Pipeline.score(reference: reference, raw: Pipeline.shifted(raw, by: offset),
                                    transcript: Pipeline.shifted(assigned, by: offset), turns: shiftedTurns, transcribes: true)
        // T4: the owner read a known text into the microphone while the meeting played.
        if let index = arguments.firstIndex(of: "--me-script"), arguments.indices.contains(index + 1) {
            let script = Metrics.words(try String(contentsOfFile: arguments[index + 1], encoding: .utf8))
            let heard = Metrics.words(raw.ordered.filter { $0.channel == .me }.map(\.text).joined(separator: " "))
            let edits = Metrics.align(script, heard)
            let inserted = edits.filter { if case .insertion = $0 { true } else { false } }.count
            report.meWER = Metrics.wer(edits, referenceCount: script.count)
            report.notes.append("me: \(heard.count) words heard for \(script.count) read; \(inserted) words that were not in the script (others leaking in, or noise)")
            report.meLeak = heard.isEmpty ? nil : Double(inserted) / Double(heard.count)
        }
        let coverage = captured.map { $0 / max(reference.duration + 3, 1) }
        report.notes.append(String(format: "offset %.2f s; others captured %@ of the played audio", offset,
                                   coverage.map { percent($0) } ?? "?"))
        print("""
        ▸ \(arguments[1]) live — offset \(String(format: "%.2f", offset)) s, captured \(coverage.map { percent($0) } ?? "?")
          others WER \(percent(report.othersWER))  me WER \(percent(report.meWER))  me leak \(percent(report.meLeak))
          DER \(percent(report.diarization?.der)) (missed \(percent(report.diarization?.missed)), false alarm \(percent(report.diarization?.falseAlarm)), confusion \(percent(report.diarization?.confusion)))
          voices found \(report.diarization.map { "\($0.hypothesisSpeakers) of \($0.referenceSpeakers)" } ?? "—")
          words to the right person \(percent(report.attribution))  words at the right moment \(percent(report.timing))
        """)
        for line in probeText.split(separator: "\n") where line.contains("capture broken") || line.contains("tap rebuilds") {
            print("  \(line)")
        }
        if arguments.contains("--gate") {
            let gate = try JSONDecoder().decode(Gate.self, from: Data(contentsOf: gateFile))
            var failures = gate.cases[arguments[1]].map { check(report, against: $0) } ?? ["no gate for \(arguments[1])"]
            if let coverage, coverage < 0.97 { failures.append("captured \(percent(coverage)) of the audio < 97 %") }
            if let leak = report.meLeak, leak > 0.05 { failures.append("\(percent(leak)) of \"me\" is not what the owner read") }
            if captured == nil { failures.append("the probe report says nothing about what was captured") }
            if failures.isEmpty { print("  ✓ gate") } else { for failure in failures { print("  ✗ \(failure)") } }
            exit(failures.isEmpty ? 0 : 1)
        }
    default:
        print("usage: meeting-bench prepare | run [--gate] [case…] | live-audio <case> | score <case> <report> [--gate]")
        exit(64)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
