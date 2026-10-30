import Foundation
import ListenKit
import Testing
@testable import MeetingKit

struct VoiceRecognitionTests {
    /// A voice: a direction in a small space, with a little per-sentence wobble.
    static func print(_ axis: Int, wobble: Float = 0, dimensions: Int = 8) -> Voiceprint {
        var values = [Float](repeating: 0, count: dimensions)
        values[axis] = 1
        values[(axis + 1) % dimensions] = wobble
        return Voiceprint(values)
    }

    static func meeting(_ voices: [String: Int], id: UUID = UUID()) -> MeetingRecord {
        var segments: [TranscriptSegment] = []
        var time = 0.0
        for (label, axis) in voices.sorted(by: { $0.key < $1.key }) {
            for index in 0..<3 {
                segments.append(TranscriptSegment(channel: .others, start: time, end: time + 3, text: "s",
                                                  speaker: label, voiceprint: print(axis, wobble: Float(index) * 0.1)))
                time += 3
            }
        }
        segments.append(TranscriptSegment(channel: .me, start: time, end: time + 2, text: "me"))
        return MeetingRecord(id: id, title: "t", sourceApp: "Teams", startedAt: Date(), duration: time,
                             transcript: Transcript(startedAt: Date(), locale: "es_ES", source: "Teams", segments: segments))
    }

    private func makeStore() throws -> MeetingStore {
        try MeetingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test func aVoiceNeedsTwoMeasuredSentences() {
        var record = Self.meeting(["speaker-1": 0])
        record.transcript.segments[1].voiceprint = nil
        record.transcript.segments[2].voiceprint = nil
        #expect(VoiceRecognition.voices(of: record.transcript).isEmpty)
    }

    @Test func proposesTheKnownPersonForTheirVoiceAndNobodyForAStranger() throws {
        let store = try makeStore()
        let first = Self.meeting(["speaker-1": 0, "speaker-2": 1])
        try store.save(first)
        let fran = try store.remember(name: "Fran", roleID: "product-owner")
        try store.learnVoice(VoiceRecognition.voices(of: first.transcript)["speaker-1"]!, of: fran.id, in: first.id)

        // Next meeting: Fran is now "speaker-2"; "speaker-1" is someone new.
        let second = Self.meeting(["speaker-1": 4, "speaker-2": 0])
        let suggestions = store.suggestions(for: second)
        #expect(suggestions["speaker-2"]?.personID == fran.id)
        #expect(suggestions["speaker-1"] == nil)
    }

    @Test func aPersonIsProposedForOneVoiceOnlyAndNotOnceRejected() throws {
        let store = try makeStore()
        let fran = try store.remember(name: "Fran", roleID: nil)
        try store.learnVoice(Self.print(0), of: fran.id, in: UUID())
        var meeting = Self.meeting(["speaker-1": 0, "speaker-2": 0])
        #expect(store.suggestions(for: meeting).count == 1)
        meeting.rejectedPeople = ["speaker-1": [fran.id], "speaker-2": [fran.id]]
        #expect(store.suggestions(for: meeting).isEmpty)
        meeting.rejectedPeople = nil
        meeting.people = ["speaker-1": fran.id]
        #expect(store.suggestions(for: meeting).isEmpty, "a person already named in the meeting is taken")
    }

    @Test func rejectingForgetsTheSampleThatCausedTheProposal() throws {
        let store = try makeStore()
        let fran = try store.remember(name: "Fran", roleID: nil)
        // A meeting where another voice (axis 3) was named Fran by mistake, and Fran's own.
        try store.learnVoice(Self.print(3), of: fran.id, in: UUID())
        try store.learnVoice(Self.print(0), of: fran.id, in: UUID())
        try store.unlearnVoice(like: Self.print(3, wobble: 0.1), of: fran.id)
        let voices = store.people().first { $0.id == fran.id }?.voices ?? []
        #expect(voices.count == 1)
        #expect(VoiceRecognition.cosine(voices[0].voiceprint.values, Self.print(0).values) > 0.99)
    }

    @Test func oneSamplePerMeetingAndTheNewestKept() throws {
        let store = try makeStore()
        let fran = try store.remember(name: "Fran", roleID: nil)
        let meeting = UUID()
        try store.learnVoice(Self.print(0), of: fran.id, in: meeting)
        try store.learnVoice(Self.print(1), of: fran.id, in: meeting)
        for _ in 0..<20 { try store.learnVoice(Self.print(2), of: fran.id, in: UUID()) }
        let voices = store.people().first { $0.id == fran.id }?.voices ?? []
        #expect(voices.count == MeetingStore.voiceSamplesPerPerson)
        #expect(!voices.contains { $0.meetingID == meeting })
    }

    @Test func learnsFromSavedMeetingsOnceAndThenRecognises() throws {
        let store = try makeStore()
        let fran = try store.remember(name: "Fran", roleID: nil)
        var old = Self.meeting(["speaker-1": 0, "speaker-2": 1])
        old.people = ["speaker-1": fran.id]
        try store.save(old)
        #expect(try store.learnVoicesFromHistory() == 1)
        #expect(try store.learnVoicesFromHistory() == 0)
        #expect(store.suggestions(for: Self.meeting(["speaker-3": 0]))["speaker-3"]?.personID == fran.id)
    }

    @Test func peopleSavedBefore13StillLoad() throws {
        let store = try makeStore()
        let old = #"[{"id":"7C1F6E6A-1C3B-4B8E-9D37-2B7A7F0E1A11","name":"Fran","roleID":"client","meetings":3,"lastSeen":1790000000000}]"#
        try Data(old.utf8).write(to: store.directory.appendingPathComponent("people.json"))
        #expect(store.people().first?.name == "Fran")
        #expect(store.people().first?.voices == nil)
    }
}

struct VoiceConflictTests {
    @Test func aNamedVoiceThatIsSomeoneElsesIsFlagged() throws {
        let store = try MeetingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let fran = try store.remember(name: "Fran", roleID: nil)
        let hugo = try store.remember(name: "Hugo", roleID: nil)
        try store.learnVoice(VoiceRecognitionTests.print(0), of: fran.id, in: UUID())
        try store.learnVoice(VoiceRecognitionTests.print(1), of: hugo.id, in: UUID())
        // Today the voice on axis 1 (Hugo's) was named Fran.
        var today = VoiceRecognitionTests.meeting(["speaker-1": 1])
        today.people = ["speaker-1": fran.id]
        try store.learnVoice(VoiceRecognition.voices(of: today.transcript)["speaker-1"]!, of: fran.id, in: today.id)
        #expect(store.conflicts(for: today)["speaker-1"]?.personID == hugo.id)
        // Named right, nothing to flag.
        today.people = ["speaker-1": hugo.id]
        #expect(store.conflicts(for: today).isEmpty)
    }
}
