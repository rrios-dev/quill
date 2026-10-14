import Testing

@testable import ListenKit

/// Names given during a meeting stay on the same voice from one diarization pass to the
/// next (`SpeakerLabeler`).
@Suite("Speaker labeler")
struct SpeakerLabelerTests {
    private func turn(_ speaker: String, _ start: Double, _ end: Double) -> SpeakerTurn {
        SpeakerTurn(speaker: speaker, start: start, end: end)
    }

    @Test("the first pass is numbered by who speaks first")
    func firstPass() {
        var labeler = SpeakerLabeler()
        let labelled = labeler.label([turn("S2", 0, 10), turn("S1", 10, 20), turn("S2", 20, 30)])
        #expect(labelled.map(\.speaker) == ["speaker-1", "speaker-2", "speaker-1"])
    }

    @Test("a later pass that renames its clusters keeps the earlier labels")
    func clustersRenamedAcrossPasses() {
        var labeler = SpeakerLabeler()
        _ = labeler.label([turn("S1", 0, 10), turn("S2", 10, 20)])
        // The diarizer now calls them the other way round, and a third voice appears.
        let second = labeler.label([turn("S2", 0, 10), turn("S1", 10, 20), turn("S3", 20, 30), turn("S2", 30, 40)])
        #expect(second.map(\.speaker) == ["speaker-1", "speaker-2", "speaker-3", "speaker-1"])
    }

    @Test("a voice that disappears does not hand its number to a newcomer")
    func numbersAreNeverReused() {
        var labeler = SpeakerLabeler()
        _ = labeler.label([turn("S1", 0, 10), turn("S2", 10, 20), turn("S3", 20, 30)])
        // speaker-2 merged into speaker-1; a new voice arrives.
        let second = labeler.label([turn("A", 0, 16), turn("B", 20, 30), turn("C", 30, 40)])
        #expect(second.map(\.speaker) == ["speaker-1", "speaker-3", "speaker-4"])
    }

    @Test("a line goes to the voice that covers most of it")
    func lineSpeaker() {
        var labeler = SpeakerLabeler()
        _ = labeler.label([turn("S1", 0, 10), turn("S2", 10, 20)])
        #expect(labeler.speaker(from: 8, to: 15) == "speaker-2")
        #expect(labeler.speaker(from: 30, to: 31) == nil)
    }

    @Test("a voice that vanishes for a pass gets its own number back when it returns")
    func returningVoiceKeepsItsNumber() {
        var labeler = SpeakerLabeler()
        _ = labeler.label([turn("S1", 0, 10), turn("S2", 10, 20), turn("S3", 20, 30)])
        // speaker-3 merged into speaker-2 for one pass.
        _ = labeler.label([turn("A", 0, 10), turn("B", 10, 30)])
        // Back, under yet another cluster name.
        let third = labeler.label([turn("X", 0, 10), turn("Y", 10, 20), turn("Z", 20, 30), turn("Z", 30, 40)])
        #expect(third.map(\.speaker) == ["speaker-1", "speaker-2", "speaker-3", "speaker-3"])
    }
}
