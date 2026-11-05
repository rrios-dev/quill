import Foundation
import ListenKit
import MeetingKit
import SpeakerKit

/// VOICES.md S5: does a voice that holds two people Quill has met before come out as those
/// two people, from their stored prints alone, without the user marking a sentence?
enum KnownVoicesBench {
    /// Rules tried, from loose to strict.
    static let rules: [Transcript.KnownSplitRule] = [0.4, 0.5, 0.6].flatMap { threshold in
        [0.05, 0.1, 0.15].flatMap { margin in
            [2, 3].map { Transcript.KnownSplitRule(threshold: Float(threshold), margin: Float(margin), minimumSentences: $0) }
        }
    }

    /// The reference speaker who said most of a segment.
    static func truth(_ segment: TranscriptSegment, in reference: Reference) -> String? {
        var seconds: [String: Double] = [:]
        for ref in reference.segments(of: "others") {
            for span in ref.spans {
                let overlap = min(span.end, segment.end) - max(span.start, segment.start)
                if overlap > 0 { seconds[ref.speaker, default: 0] += overlap }
            }
        }
        return seconds.max { $0.value < $1.value }?.key
    }

    /// A stored print as Quill keeps one: the duration-weighted mean of a meeting's sentences.
    static func sample(of clips: [Composer.Clip], embedder: SpeakerEmbedder) -> Voiceprint? {
        var sum: [Float] = []
        for clip in clips {
            guard let print = try? embedder.voiceprint(of: clip.samples) else { continue }
            let unit = VoiceSplit.unit(print)
            let weight = Float(Double(clip.samples.count) / Audio.sampleRate)
            sum = sum.isEmpty ? unit.map { $0 * weight } : zip(sum, unit).map { $0 + $1 * weight }
        }
        return sum.isEmpty ? nil : Voiceprint(VoiceSplit.unit(sum))
    }

    /// The case through the product's pipeline, each sentence measured; every pool speaker
    /// known from two earlier meetings made of the clips the case did not use (C5), so the
    /// directory holds the merged pair, the rest of the case and six strangers.
    ///
    /// `seed`: also writes a Quill data directory holding the measured meeting and the
    /// directory of people, for opening it in a debug build (`QUILL_DATA_DIR`,
    /// `QUILL_OPEN_MEETING`); the meeting's id is printed.
    static func run(case name: String, cache: URL, models: URL, seed: URL? = nil) async throws {
        let directory = cache.appendingPathComponent("cases/\(name)")
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: directory.appendingPathComponent("reference.json")))
        let (_, transcript, _) = try await Pipeline.run(caseDirectory: directory, models: models)
        let embedder = SpeakerEmbedder(modelsDirectory: models.appendingPathComponent("streaming"))
        try await embedder.prepare()
        let measured = embedder.measuringSegments(of: transcript, samples: try Audio.load(directory.appendingPathComponent("others.wav")))

        let manifest = try Composer.manifest(cache: cache)
        var profiles: [String: [Voiceprint]] = [:]
        for speaker in manifest.pool ?? [] {
            profiles[speaker.key] = [12..<18, 18..<24].compactMap {
                sample(of: (try? Composer.clips(of: speaker, cache: cache, range: $0)) ?? [], embedder: embedder)
            }
        }
        let others = measured.segments.indices.filter { measured.segments[$0].channel == .others && measured.segments[$0].voiceprint != nil }
        if let seed { try write(seed: seed, transcript: measured, profiles: profiles) }

        // How a sentence's print compares with its own person's stored prints and with the
        // closest stranger's: the margin the rule has to work with.
        var own: [Float] = [], rival: [Float] = []
        for index in others {
            guard let who = truth(measured.segments[index], in: reference), let mine = profiles[who] else { continue }
            let print = measured.segments[index].voiceprint!
            func best(_ prints: [Voiceprint]) -> Float { prints.map { VoiceRecognition.cosine(print.values, $0.values) }.max() ?? -1 }
            own.append(best(mine))
            rival.append(profiles.filter { $0.key != who }.map { best($0.value) }.max() ?? -1)
        }
        func quantiles(_ values: [Float]) -> String {
            let sorted = values.sorted()
            return [0.1, 0.5, 0.9].map { String(format: "%.2f", sorted[Int(Double(sorted.count - 1) * $0)]) }.joined(separator: " / ")
        }
        print("\(others.count) measured sentences; own person p10/p50/p90 \(quantiles(own)); closest other \(quantiles(rival)); " +
              "own ahead in \(percent(Double(zip(own, rival).filter { $0 > $1 }.count) / Double(max(own.count, 1))))")

        let labels = Set(others.compactMap { measured.segments[$0].speaker }).sorted()
        for label in labels {
            let mine = others.filter { measured.segments[$0].speaker == label }
            var counts: [String: Int] = [:]
            for index in mine { if let who = truth(measured.segments[index], in: reference) { counts[who, default: 0] += 1 } }
            let people = counts.sorted { $0.value > $1.value }
            let merged = people.count >= 2 && people[1].value >= 3
            print("voice \(label): \(people.map { "\($0.key) \($0.value)" }.joined(separator: ", "))\(merged ? "  ← merged" : "")")
            for rule in rules {
                let tag = String(format: "  ≥%.2f +%.2f ×%d:", rule.threshold, rule.margin, rule.minimumSentences)
                guard let split = measured.knownSplit(of: label, profiles: profiles, rule: rule) else {
                    print("\(tag) no split\(merged ? "  ✗ missed" : "")")
                    continue
                }
                let right = mine.filter {
                    let who = truth(measured.segments[$0], in: reference)
                    return split.moved.contains($0) ? who == split.other : who == split.kept
                }.count
                let named = people.prefix(2).map(\.key)
                let verdict = !merged ? "✗ false split" : Set([split.kept, split.other]) == Set(named) ? "✓" : "✗ wrong people"
                print("\(tag) \(split.kept) keeps, \(split.other) takes \(split.moved.count); " +
                      "\(percent(Double(right) / Double(mine.count))) of \(mine.count) right  \(verdict)")
            }
        }
    }

    /// Pool speakers by a first name, so the debug window reads like a meeting.
    static let firstNames = [
        "com_00610": "Álvaro", "com_01523": "Bruno", "com_02121": "Carlos", "pem_00295": "Darío",
        "pem_00610": "Emilio", "pem_02121": "Fede", "cof_00610": "Ana", "cof_01523": "Bea",
        "cof_02436": "Carla", "pef_00610": "Lucía", "pef_01208": "Marta", "pef_02121": "Nuria",
    ]

    static func write(seed: URL, transcript: Transcript, profiles: [String: [Voiceprint]]) throws {
        let store = try MeetingStore(directory: seed.appendingPathComponent("meetings-data", isDirectory: true))
        let record = MeetingRecord(id: UUID(), title: "Bench · voces parecidas", sourceApp: "Teams", startedAt: Date(),
                                   duration: transcript.segments.map(\.end).max() ?? 0, transcript: transcript)
        try store.save(record)
        for (key, prints) in profiles.sorted(by: { $0.key < $1.key }) {
            let person = try store.remember(name: firstNames[key] ?? key, roleID: nil)
            for print in prints { try store.learnVoice(print, of: person.id, in: UUID()) }
        }
        print("seeded \(seed.path): meeting \(record.id.uuidString)")
    }

    /// The owner's own meetings: every voice tried against the people directory, each
    /// meeting without its own samples. There is no reference, so this counts proposals
    /// for reading by hand — on voices the owner named as one person they are false.
    static func real(dataDirectory: URL) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let people = try decoder.decode([Person].self, from: Data(contentsOf: dataDirectory.appendingPathComponent("people.json")))
        let names = Dictionary(people.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let files = try FileManager.default.contentsOfDirectory(at: dataDirectory.appendingPathComponent("meetings"),
                                                                includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        print("directory: \(people.filter { !($0.voices ?? []).isEmpty }.map { "\($0.name) \($0.voices!.count)" }.joined(separator: ", "))")
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard let meeting = try? decoder.decode(MeetingRecord.self, from: Data(contentsOf: file)),
                  meeting.transcript.segments.contains(where: { $0.voiceprint != nil }) else { continue }
            var profiles: [UUID: [Voiceprint]] = [:]
            for person in people {
                let prints = (person.voices ?? []).filter { $0.meetingID != meeting.id }.map(\.voiceprint)
                if !prints.isEmpty { profiles[person.id] = prints }
            }
            let labels = Set(meeting.transcript.segments.compactMap { $0.channel == .others ? $0.speaker : nil }).sorted()
            print("meeting \(file.lastPathComponent.prefix(8)): \(labels.count) voices")
            for label in labels {
                let named = meeting.people[label].flatMap { names[$0] } ?? "unnamed"
                let measured = meeting.transcript.segments.filter { $0.speaker == label && $0.voiceprint != nil }.count
                let found = rules.compactMap { rule -> String? in
                    meeting.transcript.knownSplit(of: label, profiles: profiles, rule: rule).map {
                        String(format: "≥%.2f +%.2f ×%d %@|%@ %d", rule.threshold, rule.margin, rule.minimumSentences,
                               names[$0.kept] ?? "?", names[$0.other] ?? "?", $0.moved.count)
                    }
                }
                print("  \(label) (\(named), \(measured) measured): \(found.isEmpty ? "no split under any rule" : found.joined(separator: "; "))")
            }
        }
    }
}
