import Foundation

/// Who said a segment, as far as the capture can tell.
///
/// `me` and `others` come from different hardware: the microphone and the meeting app's
/// output. That split is exact. Telling the others apart is a separate, approximate step
/// (diarization), recorded as `speaker` labels the user can rename.
public enum Channel: String, Codable, Sendable {
    case me
    case others
}

/// A word with its time in the session. What lets a segment that spans two people be
/// split at the moment the voice changes.
public struct TimedWord: Codable, Sendable, Hashable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// One finished stretch of speech.
public struct TranscriptSegment: Codable, Sendable, Hashable {
    public var channel: Channel
    /// Seconds from the start of the session.
    public var start: Double
    public var end: Double
    public var text: String
    /// A diarization label inside `others` ("speaker-1"), or nil when not separated.
    public var speaker: String?
    /// Word timings, when the model gave them. Empty after diarization has used them.
    public var words: [TimedWord]
    /// What this stretch of voice sounds like, measured when the meeting ends: what lets
    /// the user split one voice into two people (`VoiceSplit`). Nil for `me`, for
    /// segments too short to measure and for meetings saved before it was kept.
    public var voiceprint: Voiceprint?

    public init(
        channel: Channel,
        start: Double,
        end: Double,
        text: String,
        speaker: String? = nil,
        words: [TimedWord] = [],
        voiceprint: Voiceprint? = nil
    ) {
        self.channel = channel
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        self.words = words
        self.voiceprint = voiceprint
    }
}

/// A speaker embedding: a direction that voices of the same person share. Stored as
/// base64 of its 32-bit floats, a quarter of the size of a JSON array of numbers.
/// Never audio: it cannot be turned back into speech.
public struct Voiceprint: Codable, Sendable, Hashable {
    public var values: [Float]

    public init(_ values: [Float]) {
        self.values = values
    }

    public init(from decoder: any Decoder) throws {
        let encoded = try decoder.singleValueContainer().decode(String.self)
        guard let data = Data(base64Encoded: encoded), data.count % MemoryLayout<Float>.size == 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a voiceprint"))
        }
        values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString())
    }
}

/// What a meeting leaves behind: text with times and channels. Never audio.
public struct Transcript: Codable, Sendable, Hashable {
    public var startedAt: Date
    public var locale: String
    public var source: String
    public var segments: [TranscriptSegment]
    /// Names the user gave to labels: "me" → "Roberto", "speaker-2" → "Lucía".
    public var names: [String: String]

    public init(
        startedAt: Date,
        locale: String,
        source: String,
        segments: [TranscriptSegment] = [],
        names: [String: String] = [:]
    ) {
        self.startedAt = startedAt
        self.locale = locale
        self.source = source
        self.segments = segments
        self.names = names
    }

    /// Segments in speaking order. Two channels transcribe independently and finish their
    /// segments at different moments, so arrival order is not speaking order.
    public var ordered: [TranscriptSegment] {
        segments.sorted { $0.start == $1.start ? $0.channel == .me : $0.start < $1.start }
    }

    /// The label a reader sees for a segment.
    public func label(for segment: TranscriptSegment) -> String {
        let key = segment.speaker ?? segment.channel.rawValue
        if let name = names[key] { return name }
        switch segment.channel {
        case .me: return names["me"] ?? "Yo"
        case .others: return segment.speaker.map(Self.defaultLabel) ?? "Los demás"
        }
    }

    static func defaultLabel(_ speaker: String) -> String {
        guard let number = speaker.split(separator: "-").last else { return speaker }
        return "Persona \(number)"
    }

    /// A readable transcript: consecutive segments of the same speaker merge into one turn.
    public func rendered() -> String {
        var lines: [String] = []
        var current: (label: String, start: Double, text: [String])?
        for segment in ordered {
            let label = label(for: segment)
            if current?.label == label {
                current?.text.append(segment.text)
            } else {
                if let turn = current {
                    lines.append("[\(Self.clock(turn.start))] \(turn.label): \(turn.text.joined(separator: " "))")
                }
                current = (label, segment.start, [segment.text])
            }
        }
        if let turn = current {
            lines.append("[\(Self.clock(turn.start))] \(turn.label): \(turn.text.joined(separator: " "))")
        }
        return lines.joined(separator: "\n")
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
