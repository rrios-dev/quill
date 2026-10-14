import AVFAudio
import Foundation

/// A bench case: the audio of each channel and the reference that says who said what
/// and when.
struct Reference: Codable {
    struct Segment: Codable {
        var channel: String
        var speaker: String
        var start: Double
        var end: Double
        var text: String
        /// Where inside the sentence there is actually voice: read speech has pauses, and
        /// scoring them as speech would charge the diarizer for silence it rightly left
        /// out. Nil means the whole span (AMI's word-level turns already are).
        var regions: [[Double]]? = nil

        /// The spans that count as this speaker talking.
        var spans: [(start: Double, end: Double)] {
            regions.map { $0.map { (start + $0[0], start + $0[1]) } } ?? [(start, end)]
        }
    }

    var name: String
    var locale: String
    var duration: Double
    var description: String
    /// Channel → audio file name in the case directory.
    var audio: [String: String]
    var segments: [Segment]

    func segments(of channel: String) -> [Segment] {
        segments.filter { $0.channel == channel }.sorted { $0.start < $1.start }
    }
}

/// 16 kHz mono float audio: what both the speech model and the diarizer take.
enum Audio {
    static let sampleRate = 16_000.0
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw BenchError("cannot allocate \(url.lastPathComponent)")
        }
        try file.read(into: input)
        if source.sampleRate == sampleRate, source.channelCount == 1, source.commonFormat == .pcmFormatFloat32 {
            return Array(UnsafeBufferPointer(start: input.floatChannelData![0], count: Int(input.frameLength)))
        }
        guard let converter = AVAudioConverter(from: source, to: format) else { throw BenchError("no converter") }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * sampleRate / source.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw BenchError("alloc") }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    static func write(_ samples: [Float], to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else {
            throw BenchError("alloc")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// The stretches with voice, relative to the clip's start: 20 ms windows within 30 dB
    /// of the clip's loudest, joined across gaps under 300 ms, at least 100 ms long.
    static func voicedRegions(_ samples: [Float]) -> [[Double]] {
        let window = Int(sampleRate * 0.02)
        let levels = stride(from: 0, to: samples.count, by: window).map {
            rms(samples[$0..<min($0 + window, samples.count)])
        }
        let threshold = (levels.max() ?? 0) * 0.0316
        var regions: [[Double]] = []
        for (index, level) in levels.enumerated() where level > threshold {
            let start = Double(index) * 0.02, end = start + 0.02
            if let last = regions.last, start - last[1] < 0.3 {
                regions[regions.count - 1][1] = end
            } else {
                regions.append([start, end])
            }
        }
        return regions.filter { $0[1] - $0[0] >= 0.1 }
    }

    /// The span that holds speech: from the first to the last 20 ms window louder than
    /// 40 dB below the loudest one, with 60 ms of margin.
    static func speechSpan(_ samples: [Float]) -> Range<Int> {
        let window = Int(sampleRate * 0.02)
        let levels = stride(from: 0, to: samples.count, by: window).map {
            rms(samples[$0..<min($0 + window, samples.count)])
        }
        let peak = levels.max() ?? 0
        let threshold = peak * 0.01
        guard let first = levels.firstIndex(where: { $0 > threshold }),
              let last = levels.lastIndex(where: { $0 > threshold }) else { return 0..<samples.count }
        let margin = Int(sampleRate * 0.06)
        return max(0, first * window - margin)..<min(samples.count, (last + 1) * window + margin)
    }
}

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Deterministic randomness, so a composed meeting is the same on every run.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// C2: a Spanish meeting composed from real voices (OpenSLR, see fetch_corpus.py).
///
/// What makes it a meeting rather than a playlist: turns of one or two sentences that
/// alternate between five people, pauses of varying length, interruptions where the next
/// person starts before the last one finished, one person much quieter than the rest,
/// and "me" on its own channel as the microphone would give it. A second case adds
/// background noise at 15 dB SNR. The reference keeps the exact text and span of every
/// sentence.
enum Composer {
    struct Manifest: Decodable {
        struct Speaker: Decodable {
            struct Clip: Decodable { var file: String; var text: String }
            var key: String
            var role: String
            var clips: [Clip]
        }
        var speakers: [Speaker]
    }

    static let quietSpeaker = "pem_01208"

    static func compose(cache: URL) throws -> [URL] {
        let root = cache.appendingPathComponent("openslr")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        var rng = SplitMix64(state: 20_261_008)

        // Every clip trimmed to its speech and brought to the same loudness, so levels are
        // a choice of the composition (the quiet speaker), not of each volunteer's microphone.
        var queues: [String: [(samples: [Float], text: String, regions: [[Double]])]] = [:]
        var roles: [String: String] = [:]
        for speaker in manifest.speakers {
            roles[speaker.key] = speaker.role
            queues[speaker.key] = try speaker.clips.map { clip in
                let full = try Audio.load(root.appendingPathComponent(clip.file))
                var samples = Array(full[Audio.speechSpan(full)])
                let gain = 0.08 / max(Audio.rms(samples[...]), 1e-4) * (speaker.key == quietSpeaker ? 0.3 : 1)
                for index in samples.indices { samples[index] *= gain }
                return (samples, clip.text, Audio.voicedRegions(samples))
            }
        }
        let others = manifest.speakers.filter { $0.role == "others" }.map(\.key)
        let me = manifest.speakers.first { $0.role == "me" }?.key

        var segments: [Reference.Segment] = []
        var tracks: [String: [Float]] = ["others": [], "me": []]
        func place(_ samples: [Float], at start: Double, channel: String) {
            let offset = Int(start * Audio.sampleRate)
            if tracks[channel]!.count < offset + samples.count {
                tracks[channel]!.append(contentsOf: repeatElement(0, count: offset + samples.count - tracks[channel]!.count))
            }
            for (index, value) in samples.enumerated() { tracks[channel]![offset + index] += value }
        }

        var clock = 1.0
        var previous: (speaker: String, start: Double, end: Double)?
        while queues.values.contains(where: { !$0.isEmpty }) {
            let meReady = me.map { !(queues[$0]?.isEmpty ?? true) } ?? false
            let candidates = others.filter { !(queues[$0]?.isEmpty ?? true) && $0 != previous?.speaker }
            let speaker: String
            if meReady, me != previous?.speaker, Double.random(in: 0..<1, using: &rng) < 0.15 || candidates.isEmpty {
                speaker = me!
            } else if let pick = candidates.randomElement(using: &rng) {
                speaker = pick
            } else if let rest = others.first(where: { !(queues[$0]?.isEmpty ?? true) }) {
                speaker = rest
            } else {
                break
            }
            let channel = roles[speaker] == "me" ? "me" : "others"
            var start = clock + Double.random(in: 0.25..<1.2, using: &rng)
            // An interruption: the next person starts before the last one finished.
            if let previous, channel == "others", roles[previous.speaker] == "others",
               Double.random(in: 0..<1, using: &rng) < 0.12 {
                start = max(previous.start + 0.5, previous.end - Double.random(in: 0.4..<1.2, using: &rng))
            }
            let count = Double.random(in: 0..<1, using: &rng) < 0.4 ? 2 : 1
            var cursor = start
            for _ in 0..<count {
                guard let clip = queues[speaker]?.first else { break }
                queues[speaker]!.removeFirst()
                let duration = Double(clip.samples.count) / Audio.sampleRate
                place(clip.samples, at: cursor, channel: channel)
                segments.append(.init(channel: channel, speaker: speaker, start: cursor, end: cursor + duration,
                                      text: clip.text, regions: clip.regions))
                cursor += duration + 0.15
            }
            previous = (speaker, start, cursor - 0.15)
            clock = max(clock, cursor - 0.15)
        }
        let length = max(tracks["others"]!.count, tracks["me"]!.count) + Int(Audio.sampleRate)
        for channel in ["others", "me"] {
            tracks[channel]!.append(contentsOf: repeatElement(0, count: length - tracks[channel]!.count))
        }

        // Background noise at 15 dB below the speech: low-passed random noise, like a fan
        // or a room, the same on every run.
        let speech = segments.filter { $0.channel == "others" }.flatMap { segment in
            tracks["others"]![Int(segment.start * Audio.sampleRate)..<Int(segment.end * Audio.sampleRate)]
        }
        let speechLevel = Audio.rms(speech[...])
        var noise = [Float](repeating: 0, count: length)
        var state: Float = 0
        for index in noise.indices {
            state = 0.95 * state + Float.random(in: -1...1, using: &rng)
            noise[index] = state
        }
        let noiseGain = speechLevel / pow(10, 15 / 20) / max(Audio.rms(noise[...]), 1e-6)
        let noisy = zip(tracks["others"]!, noise).map { $0 + $1 * noiseGain }

        let duration = Double(length) / Audio.sampleRate
        var written: [URL] = []
        for (name, othersAudio, description) in [
            ("c2-es", tracks["others"]!, "Five real Spanish voices composed into a meeting, plus me"),
            ("c2-es-noise", noisy, "C2 with background noise at 15 dB SNR"),
        ] {
            let directory = cache.appendingPathComponent("cases/\(name)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Audio.write(othersAudio, to: directory.appendingPathComponent("others.wav"))
            try Audio.write(tracks["me"]!, to: directory.appendingPathComponent("me.wav"))
            let reference = Reference(name: name, locale: "es_ES", duration: duration, description: description,
                                      audio: ["others": "others.wav", "me": "me.wav"], segments: segments)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(reference).write(to: directory.appendingPathComponent("reference.json"))
            written.append(directory)
        }
        return written
    }
}

/// C3: AMI ES2004a, a real meeting in English (see fetch_ami.py). Reference turns are the
/// annotators' words grouped while one person keeps talking.
enum AMICase {
    static func prepare(cache: URL) throws -> URL {
        let root = cache.appendingPathComponent("ami/ES2004a")
        var segments: [Reference.Segment] = []
        for speaker in ["A", "B", "C", "D"] {
            let words = try parseWords(root.appendingPathComponent("ES2004a.\(speaker).words.xml"))
            var current: Reference.Segment?
            for word in words {
                if var open = current, word.start - open.end < 0.6 {
                    open.end = max(open.end, word.end)
                    open.text += " " + word.text
                    current = open
                } else {
                    if let open = current { segments.append(open) }
                    current = .init(channel: "others", speaker: speaker, start: word.start, end: word.end, text: word.text)
                }
            }
            if let open = current { segments.append(open) }
        }
        segments.sort { $0.start < $1.start }
        let directory = cache.appendingPathComponent("cases/c3-ami")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = try Audio.load(root.appendingPathComponent("ES2004a.Mix-Headset.wav"))
        try Audio.write(audio, to: directory.appendingPathComponent("others.wav"))
        let reference = Reference(name: "c3-ami", locale: "en_US", duration: Double(audio.count) / Audio.sampleRate,
                                  description: "AMI ES2004a: four people in a room, unscripted, real overlap",
                                  audio: ["others": "others.wav"], segments: segments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(reference).write(to: directory.appendingPathComponent("reference.json"))
        return directory
    }

    struct Word { var start: Double; var end: Double; var text: String }

    /// `<w starttime= endtime=>text</w>`, without punctuation entries.
    static func parseWords(_ url: URL) throws -> [Word] {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .isoLatin1) ?? ""
        let pattern = try NSRegularExpression(pattern: #"<w [^>]*starttime="([\d.]+)" endtime="([\d.]+)"([^>]*)>([^<]*)</w>"#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            func group(_ index: Int) -> String { String(text[Range(match.range(at: index), in: text)!]) }
            guard !group(3).contains("punc=\"true\""), let start = Double(group(1)), let end = Double(group(2)) else { return nil }
            return Word(start: start, end: end, text: group(4))
        }
    }
}
