import Foundation
import ListenKit
import SpeakerKit

/// C4: a meeting of people who sound alike — the failure the owner met in real meetings,
/// two people coming out as one voice (docs/initiatives/quill/VOICES.md).
///
/// The voices are not picked by ear: each pool speaker's voiceprint is measured on the
/// first half of their clips, and the case takes the most alike pair of men and the most
/// alike pair of women. C2's "me" joins on the microphone channel.
enum SimilarVoices {
    struct Similarity: Codable {
        var a: String
        var b: String
        var cosine: Double
    }

    /// The clips that measure a voice and compose C4; C5 keeps the second half unheard.
    static let firstHalf = 0..<12

    static func compose(cache: URL, models: URL) async throws -> URL {
        let manifest = try Composer.manifest(cache: cache)
        guard let pool = manifest.pool, pool.count >= 4 else { throw BenchError("no voice pool: run fetch_corpus.py again") }
        let separator = SpeakerSeparator(modelsDirectory: models)
        try await separator.prepare()

        var clips: [String: [Composer.Clip]] = [:]
        var prints: [String: [Float]] = [:]
        for speaker in pool {
            clips[speaker.key] = try Composer.clips(of: speaker, cache: cache, range: firstHalf)
            prints[speaker.key] = try await voiceprint(of: clips[speaker.key]!, separator: separator)
        }
        var pairs: [Similarity] = []
        for (i, a) in pool.enumerated() {
            for b in pool[(i + 1)...] where isFemale(a) == isFemale(b) {
                pairs.append(Similarity(a: a.key, b: b.key, cosine: cosine(prints[a.key]!, prints[b.key]!)))
            }
        }
        pairs.sort { $0.cosine > $1.cosine }
        guard let men = pairs.first(where: { p in pool.contains { $0.key == p.a && !isFemale($0) } }),
              let women = pairs.first(where: { p in pool.contains { $0.key == p.a && isFemale($0) } })
        else { throw BenchError("the pool needs two men and two women") }
        print("most alike men \(men.a) · \(men.b) \(String(format: "%.2f", men.cosine)); " +
              "women \(women.a) · \(women.b) \(String(format: "%.2f", women.cosine))")

        let others = [men.a, women.a, men.b, women.b]
        var queues = clips.filter { others.contains($0.key) }
        if let me = manifest.speakers.first(where: { $0.role == "me" }) {
            queues[me.key] = try Composer.clips(of: me, cache: cache)
        }
        var rng = SplitMix64(state: 20_261_025)
        let meeting = Composer.compose(others: others, me: manifest.speakers.first { $0.role == "me" }?.key,
                                       queues: queues, rng: &rng)
        let directory = try Composer.write(
            name: "c4-similar",
            description: "Two pairs of the most alike voices of the pool (\(men.a)·\(men.b), \(women.a)·\(women.b)), plus me",
            tracks: meeting.tracks, segments: meeting.segments, cache: cache)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(pairs).write(to: directory.appendingPathComponent("similarity.json"))
        return directory
    }

    /// The voiceprint of the voice that holds most of a speaker's clips, read together.
    static func voiceprint(of clips: [Composer.Clip], separator: SpeakerSeparator) async throws -> [Float] {
        let gap = [Float](repeating: 0, count: Int(Audio.sampleRate * 0.4))
        let samples = clips.flatMap { $0.samples + gap }
        let separated = try await separator.separate(samples)
        var seconds: [String: Double] = [:]
        for turn in separated.turns { seconds[turn.speaker, default: 0] += turn.end - turn.start }
        guard let main = seconds.max(by: { $0.value < $1.value })?.key, let print = separated.voiceprints[main] else {
            throw BenchError("no voiceprint")
        }
        return print
    }

    static func isFemale(_ speaker: Composer.Manifest.Speaker) -> Bool {
        speaker.dataset?.contains("female") ?? false
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        let dot = zip(a, b).reduce(0) { $0 + Double($1.0) * Double($1.1) }
        let na = a.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
        let nb = b.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
        return dot / max(na * nb, 1e-12)
    }
}

extension SimilarVoices {
    /// Can two voices be told apart sentence by sentence, when their average voiceprints
    /// cannot? Each clip gets its own voiceprint; scored as leave-one-out nearest centroid
    /// (with the answer known) and as an unsupervised split in two (what "these are two
    /// people" would do), each as the share of clips on the right side.
    static func separability(cache: URL, models: URL, a: String, b: String) async throws {
        let manifest = try Composer.manifest(cache: cache)
        let speakers = (manifest.pool ?? []) + manifest.speakers
        guard let first = speakers.first(where: { $0.key == a }), let second = speakers.first(where: { $0.key == b }) else {
            throw BenchError("unknown speaker")
        }
        let separator = SpeakerSeparator(modelsDirectory: models)
        try await separator.prepare()
        // BENCH_EMBEDDER=wespeaker: the streaming model's voiceprint instead of the offline pipeline's.
        let embedder: SpeakerEmbedder? = ProcessInfo.processInfo.environment["BENCH_EMBEDDER"] == "wespeaker"
            ? SpeakerEmbedder(modelsDirectory: models.appendingPathComponent("streaming")) : nil
        try await embedder?.prepare()
        var prints: [(speaker: Int, print: [Float])] = []
        for (index, speaker) in [first, second].enumerated() {
            for clip in try Composer.clips(of: speaker, cache: cache) {
                if let embedder {
                    if let print = try? embedder.voiceprint(of: clip.samples) { prints.append((index, print)) }
                } else if let print = try? await voiceprint(of: [clip], separator: separator) {
                    prints.append((index, print))
                }
            }
        }
        func centroid(_ rows: [[Float]]) -> [Float] {
            guard let first = rows.first else { return [] }
            return rows.dropFirst().reduce(first) { zip($0, $1).map(+) }
        }
        var right = 0
        for (i, row) in prints.enumerated() {
            let rest = prints.enumerated().filter { $0.offset != i }.map(\.element)
            let scores = (0..<2).map { s in cosine(row.print, centroid(rest.filter { $0.speaker == s }.map(\.print))) }
            if (scores[0] > scores[1] ? 0 : 1) == row.speaker { right += 1 }
        }
        let split = VoiceSplit.twoWay(prints.map(\.print))
        let agree = zip(split, prints).filter { $0.0 == $0.1.speaker }.count
        let unsupervised = max(agree, prints.count - agree)
        print("\(a) · \(b): \(prints.count) clips; cosine of averages \(String(format: "%.2f", cosine(centroid(prints.filter { $0.speaker == 0 }.map(\.print)), centroid(prints.filter { $0.speaker == 1 }.map(\.print)))))")
        // What the user does: mark k sentences of each person, Quill sorts the rest.
        var marked: [String] = []
        for k in [1, 2, 3] {
            var known: [Int: Int] = [:]
            for s in 0..<2 { for index in prints.indices.filter({ prints[$0].speaker == s }).prefix(k) { known[index] = s } }
            let groups = VoiceSplit.twoWay(prints.map(\.print), known: known)
            let rest = prints.indices.filter { known[$0] == nil }
            let right = rest.filter { groups[$0] == prints[$0].speaker }.count
            marked.append("\(k) marked \(percent(Double(right) / Double(rest.count)))")
        }
        print("  both people marked: " + marked.joined(separator: "  "))
        // The lighter gesture: mark only sentences of the second person; the voice's other
        // sentences stand for the first. Scored on the unmarked sentences.
        var oneSide: [String] = []
        for k in [1, 2, 3, 5] {
            let marks = Set(prints.indices.filter { prints[$0].speaker == 1 }.prefix(k))
            let groups = VoiceSplit.peelingOff(prints.map(\.print), marked: marks)
            let rest = prints.indices.filter { !marks.contains($0) }
            let right = rest.filter { groups[$0] == prints[$0].speaker }.count
            oneSide.append("\(k) marked \(percent(Double(right) / Double(rest.count)))")
        }
        print("  only the other person marked: " + oneSide.joined(separator: "  "))
        print("  told apart knowing the answer \(percent(Double(right) / Double(prints.count)))  split in two blind \(percent(Double(unsupervised) / Double(prints.count)))")
    }
}
