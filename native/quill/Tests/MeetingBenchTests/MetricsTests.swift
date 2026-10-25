import Testing

@testable import MeetingBench

/// The bench's numbers are only worth what their definitions are: checked here on cases
/// small enough to work out by hand.
@Suite("Meeting bench metrics")
struct MetricsTests {
    @Test("words fold case, accents and punctuation, and keep numbers")
    func normalisation() {
        #expect(Metrics.words("¿Está listo? Sí, a las 10.") == ["esta", "listo", "si", "a", "las", "10"])
    }

    @Test("WER counts substitutions, deletions and insertions over the reference")
    func wordErrorRate() {
        let reference = ["el", "volcado", "es", "el", "sabado"]
        let hypothesis = ["el", "volcado", "sera", "el", "sabado", "noche"]
        let edits = Metrics.align(reference, hypothesis)
        #expect(Metrics.wer(edits, referenceCount: reference.count) == 2.0 / 5.0)
        #expect(Metrics.wer(Metrics.align(reference, reference), referenceCount: 5) == 0)
        #expect(Metrics.wer(Metrics.align(reference, []), referenceCount: 5) == 1)
    }

    @Test("two people whose speech went mostly to one voice are a merge; a voice per person is none")
    func merged() {
        let reference = [Metrics.Turn(speaker: "ana", start: 0, end: 10), .init(speaker: "eva", start: 10, end: 20),
                         .init(speaker: "luis", start: 20, end: 30)]
        let oneForTwo = [Metrics.Turn(speaker: "S1", start: 0, end: 19), .init(speaker: "S2", start: 19, end: 30)]
        #expect(Metrics.merged(reference: reference, hypothesis: oneForTwo) == [["ana", "eva"]])
        let separate = [Metrics.Turn(speaker: "S1", start: 0, end: 10), .init(speaker: "S2", start: 10, end: 20),
                        .init(speaker: "S3", start: 20, end: 30)]
        #expect(Metrics.merged(reference: reference, hypothesis: separate).isEmpty)
    }

    @Test("speakers are mapped one to one by the time they share, whatever their labels")
    func mapping() {
        let reference = [Metrics.Turn(speaker: "lucia", start: 0, end: 10), .init(speaker: "marta", start: 10, end: 20)]
        let hypothesis = [Metrics.Turn(speaker: "S2", start: 0, end: 9), .init(speaker: "S1", start: 9, end: 20)]
        #expect(Metrics.mapping(reference: reference, hypothesis: hypothesis) == ["S2": "lucia", "S1": "marta"])
    }

    @Test("a perfect diarization scores zero; one voice for two scores the confusion")
    func diarizationErrorRate() {
        let reference = [Metrics.Turn(speaker: "a", start: 0, end: 10), .init(speaker: "b", start: 10, end: 20)]
        let perfect = [Metrics.Turn(speaker: "x", start: 0, end: 10), .init(speaker: "y", start: 10, end: 20)]
        let merged = [Metrics.Turn(speaker: "x", start: 0, end: 20)]
        let good = Metrics.diarization(reference: reference, hypothesis: perfect,
                                       mapping: Metrics.mapping(reference: reference, hypothesis: perfect))
        #expect(good.der < 0.001)
        let bad = Metrics.diarization(reference: reference, hypothesis: merged,
                                      mapping: Metrics.mapping(reference: reference, hypothesis: merged))
        #expect(abs(bad.confusion - 0.5) < 0.01)
        #expect(bad.missed < 0.001 && bad.falseAlarm < 0.001)
        #expect(bad.hypothesisSpeakers == 1 && bad.referenceSpeakers == 2)
    }

    @Test("overlapped speech counts each speaker, and missing one is a miss")
    func overlap() {
        let reference = [Metrics.Turn(speaker: "a", start: 0, end: 10), .init(speaker: "b", start: 5, end: 10)]
        let hypothesis = [Metrics.Turn(speaker: "x", start: 0, end: 10)]
        let result = Metrics.diarization(reference: reference, hypothesis: hypothesis,
                                         mapping: Metrics.mapping(reference: reference, hypothesis: hypothesis))
        // 15 s of reference speech, 5 s of b never found.
        #expect(abs(result.missed - 5.0 / 15.0) < 0.01)
        #expect(abs(result.der - 5.0 / 15.0) < 0.01)
    }

    @Test("the assignment is optimal, not greedy")
    func hungarianIsOptimal() {
        // Greedy would take (0,0)=1 and then pay 10; the optimum pays 2 + 2.
        #expect(Metrics.hungarian([[1, 2], [2, 10]]) == [1, 0])
    }
}
