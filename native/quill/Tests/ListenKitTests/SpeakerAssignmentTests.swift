import Foundation
import Testing

@testable import ListenKit

/// Splitting the others' channel by voice (`Transcript.assigningSpeakers`).
@Suite("Speaker assignment")
struct SpeakerAssignmentTests {
    private func word(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
        TimedWord(text: text, start: start, end: end)
    }

    private func transcript(_ segments: [TranscriptSegment]) -> Transcript {
        Transcript(startedAt: Date(timeIntervalSince1970: 0), locale: "es_ES", source: "test", segments: segments)
    }

    @Test("a segment that holds two voices is split where the voice changes")
    func splitsASegmentAtTheVoiceChange() {
        // The transcriber cut at a pause, not at the change of speaker: one segment, two people.
        let segment = TranscriptSegment(
            channel: .others, start: 0, end: 4, text: "Hola a todos. Yo me encargo.",
            words: [
                word("Hola", 0.0, 0.4), word(" a", 0.4, 0.5), word(" todos.", 0.5, 1.0),
                word(" Yo", 2.1, 2.4), word(" me", 2.4, 2.6), word(" encargo.", 2.6, 3.2),
            ]
        )
        let turns = [
            SpeakerTurn(speaker: "S7", start: 0, end: 1.2),
            SpeakerTurn(speaker: "S3", start: 2.0, end: 3.5),
        ]

        let result = transcript([segment]).assigningSpeakers(turns)

        #expect(result.segments.map(\.speaker) == ["speaker-1", "speaker-2"])
        #expect(result.segments.map(\.text) == ["Hola a todos.", "Yo me encargo."])
        #expect(result.segments[1].start == 2.1)
    }

    @Test("labels are renumbered by who speaks first, whatever the diarizer called them")
    func renumbersByFirstAppearance() {
        let segments = [
            TranscriptSegment(channel: .others, start: 5, end: 6, text: "Segunda", words: [word("Segunda", 5, 6)]),
            TranscriptSegment(channel: .others, start: 0, end: 1, text: "Primera", words: [word("Primera", 0, 1)]),
        ]
        let turns = [SpeakerTurn(speaker: "S9", start: 0, end: 1), SpeakerTurn(speaker: "S2", start: 5, end: 6)]

        let result = transcript(segments).assigningSpeakers(turns)

        #expect(result.ordered.map(\.speaker) == ["speaker-1", "speaker-2"])
    }

    @Test("a word in a gap between turns goes to the nearest one")
    func gapWordGoesToTheNearestTurn() {
        let segment = TranscriptSegment(
            channel: .others, start: 1.0, end: 1.2, text: "vale", words: [word("vale", 1.0, 1.2)]
        )
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 0.9), SpeakerTurn(speaker: "B", start: 3, end: 4)]

        let result = transcript([segment]).assigningSpeakers(turns)

        #expect(result.segments.map(\.speaker) == ["speaker-1"])
    }

    @Test("the user's own channel is never relabelled: that split comes from hardware")
    func meIsLeftAlone() {
        let me = TranscriptSegment(channel: .me, start: 0, end: 1, text: "Yo", words: [word("Yo", 0, 1)])
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 1)]

        let result = transcript([me]).assigningSpeakers(turns)

        #expect(result.segments == [me])
        #expect(result.rendered().contains("Yo: Yo"))
    }

    @Test("without turns the transcript is unchanged")
    func noTurnsNoChange() {
        let segment = TranscriptSegment(channel: .others, start: 0, end: 1, text: "Hola")
        #expect(transcript([segment]).assigningSpeakers([]) == transcript([segment]))
    }

    @Test("names given by the user replace the default labels")
    func namesReplaceLabels() {
        var result = transcript([
            TranscriptSegment(channel: .me, start: 0, end: 1, text: "Hola"),
            TranscriptSegment(channel: .others, start: 2, end: 3, text: "Buenas", speaker: "speaker-1"),
        ])
        #expect(result.rendered() == "[00:00:00] Yo: Hola\n[00:00:02] Persona 1: Buenas")

        result.names = ["me": "Roberto", "speaker-1": "Lucía"]
        #expect(result.rendered() == "[00:00:00] Roberto: Hola\n[00:00:02] Lucía: Buenas")
    }
}

/// Folding the voices a diarizer invents at interruptions (`absorbingMinorVoices`).
@Suite("Minor voices")
struct MinorVoiceTests {
    private func turn(_ speaker: String, _ start: Double, _ end: Double) -> SpeakerTurn {
        SpeakerTurn(speaker: speaker, start: start, end: end)
    }

    @Test("a voice of a few seconds inside an interruption goes to the person it overlaps")
    func ghostGoesToOverlap() {
        let turns = [turn("S1", 0, 200), turn("S2", 200, 400), turn("S3", 199, 202)]
        let result = SpeakerTurn.absorbingMinorVoices(turns)
        #expect(Set(result.map(\.speaker)) == ["S1", "S2"])
        #expect(result[2].speaker == "S2", "it overlaps S1 by 1 s and S2 by 2 s")
    }

    @Test("with no overlap it goes to the nearest main turn")
    func ghostGoesToNearest() {
        let turns = [turn("S1", 0, 100), turn("S2", 150, 300), turn("S3", 140, 145)]
        #expect(SpeakerTurn.absorbingMinorVoices(turns)[2].speaker == "S2")
    }

    @Test("a short meeting's quiet person is not a ghost when they are a real share of it")
    func realShareStays() {
        let turns = [turn("S1", 0, 60), turn("S2", 60, 120), turn("S3", 120, 130)]
        #expect(SpeakerTurn.absorbingMinorVoices(turns) == turns, "10 s of 130 is over 5 %")
    }

    @Test("a voice over fifteen seconds stays, however long the meeting")
    func longVoiceStays() {
        let turns = [turn("S1", 0, 3000), turn("S2", 3000, 6000), turn("S3", 6000, 6020)]
        #expect(SpeakerTurn.absorbingMinorVoices(turns) == turns)
    }
}
