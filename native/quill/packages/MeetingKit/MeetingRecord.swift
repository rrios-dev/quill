import Foundation
import ListenKit
import SynthesisKit

/// One meeting as Quill keeps it: the transcript, who was who, and every synthesis made
/// of it. Never audio (MEETINGS.md M-02).
public struct MeetingRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    /// The app's name as shown to the user ("Microsoft Teams").
    public var sourceApp: String
    public var startedAt: Date
    public var duration: Double
    public var transcript: Transcript
    /// Transcript label ("me", "speaker-2") → the person it turned out to be.
    public var people: [String: UUID]
    public var syntheses: [SynthesisRecord]
    /// Seconds of audio each channel received ("others", "me"), as the capture counted
    /// them. Nil for meetings saved before it was kept.
    public var capturedSeconds: [String: Double]?
    /// A turn's text → its translation into `translationLanguage`, for meetings held in
    /// another language than the user's. Made on the Mac (Translation framework), kept so
    /// it is done once.
    public var translations: [String: String]?
    public var translationLanguage: String?

    public init(
        id: UUID = UUID(),
        title: String,
        sourceApp: String,
        startedAt: Date,
        duration: Double,
        transcript: Transcript,
        people: [String: UUID] = [:],
        syntheses: [SynthesisRecord] = [],
        capturedSeconds: [String: Double]? = nil
    ) {
        self.id = id
        self.title = title
        self.sourceApp = sourceApp
        self.startedAt = startedAt
        self.duration = duration
        self.transcript = transcript
        self.people = people
        self.syntheses = syntheses
        self.capturedSeconds = capturedSeconds
    }

    /// Channels that heard much less than the meeting lasted: a capture that died.
    ///
    /// The first real call (2026-10-08) was saved with the others' channel empty and
    /// nothing said it anywhere; it read as a meeting where only one person spoke. Now
    /// the meeting says so itself.
    public var silentChannels: [Channel] {
        guard let captured = capturedSeconds, duration >= 30 else { return [] }
        return [Channel.others, .me].filter { channel in
            captured[channel.rawValue].map { $0 < duration * 0.8 } ?? false
        }
    }

    /// The labels the transcript uses, in order of first appearance: "me" first if present.
    public var labels: [String] {
        var seen: [String] = []
        for segment in transcript.ordered {
            let label = segment.speaker ?? segment.channel.rawValue
            if !seen.contains(label) { seen.append(label) }
        }
        return seen.sorted { lhs, rhs in lhs == "me" && rhs != "me" }
    }

    /// Everything a search looks at.
    var searchableText: String {
        ([title, sourceApp] + transcript.segments.map(\.text) + syntheses.map(\.text)
            + Array(transcript.names.values)).joined(separator: "\n")
    }
}

/// One synthesis of a meeting, with the weighting it used, so the history can say how
/// a reading was made (MEETINGS.md §7.3).
public struct SynthesisRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var focusID: String
    public var focusName: String
    /// "provider:model".
    public var model: String
    public var createdAt: Date
    public var text: String
    public var participants: [Participant]
    /// The model stopped at its output limit: not a finished synthesis.
    public var truncated: Bool
    /// A draft from the on-device model (MEETINGS.md §4, S3).
    public var isDraft: Bool

    public init(
        id: UUID = UUID(),
        focusID: String,
        focusName: String,
        model: String,
        createdAt: Date = Date(),
        text: String,
        participants: [Participant],
        truncated: Bool = false,
        isDraft: Bool = false
    ) {
        self.id = id
        self.focusID = focusID
        self.focusName = focusName
        self.model = model
        self.createdAt = createdAt
        self.text = text
        self.participants = participants
        self.truncated = truncated
        self.isDraft = isDraft
    }
}

/// Someone heard in meetings, remembered with their usual role.
public struct Person: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var roleID: String?
    public var meetings: Int
    public var lastSeen: Date

    public init(id: UUID = UUID(), name: String, roleID: String? = nil, meetings: Int = 0, lastSeen: Date = Date()) {
        self.id = id
        self.name = name
        self.roleID = roleID
        self.meetings = meetings
        self.lastSeen = lastSeen
    }
}

/// What the history list shows, without loading every transcript.
public struct MeetingSummary: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var sourceApp: String
    public var startedAt: Date
    public var duration: Double
    public var peopleCount: Int
    public var synthesisCount: Int
}
