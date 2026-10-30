import Foundation
import ListenKit
import Testing
@testable import MeetingKit

struct VocabularyTests {
    private func makeStore() throws -> MeetingStore {
        try MeetingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test func aCorrectionKeepsOnlyTheWordsThatChanged() {
        let found = Vocabulary.replacements(from: "Hay que desplegar en cuber netes mañana.",
                                            to: "Hay que desplegar en Kubernetes mañana.")
        #expect(found.map(\.heard) == ["cuber netes"])
        #expect(found.map(\.written) == ["Kubernetes"])
    }

    @Test func caseAndPunctuationAloneAreNotVocabulary() {
        #expect(Vocabulary.replacements(from: "hola, fran", to: "Hola, Fran.").isEmpty)
    }

    @Test func addedOrRemovedWordsAndRewritesAreNotVocabulary() {
        #expect(Vocabulary.replacements(from: "vamos a ver", to: "vamos a ver mañana").isEmpty)
        #expect(Vocabulary.replacements(from: "esto lo vemos luego con el equipo", to: "lo revisamos el jueves por la tarde con calma").isEmpty)
    }

    @Test func twoCorrectionsInOneSentence() {
        let found = Vocabulary.replacements(from: "el sprin de jira", to: "el sprint de Jira")
        // "jira" → "Jira" is case only; "sprin" → "sprint" is a word.
        #expect(found.map(\.written) == ["sprint"])
    }

    @Test func appliesWholeWordsIgnoringCase() {
        let entries = [VocabularyEntry(heard: "cuber netes", written: "Kubernetes", scope: .global),
                       VocabularyEntry(heard: "sprin", written: "sprint", scope: .global)]
        #expect(Vocabulary.apply(entries, to: "Cuber netes y el sprin; no sprinter.") == "Kubernetes y el sprint; no sprinter.")
    }

    @Test func aCorrectionBelongsToWhoeverSaidItAndGoesGlobalOnRequest() throws {
        let store = try makeStore()
        let fran = UUID(), delia = UUID()
        let first = try store.learn(heard: "cuber netes", written: "Kubernetes", scope: .person(fran))
        #expect(first.alsoFor.isEmpty)
        let again = try store.learn(heard: "Cuber netes", written: "Kubernetes", scope: .person(fran))
        #expect(again.entry.uses == 2)
        let second = try store.learn(heard: "cuber netes", written: "Kubernetes", scope: .person(delia))
        #expect(second.alsoFor == [.person(fran)])
        #expect(store.vocabulary(for: .me).isEmpty, "a person's correction is not mine")
        try store.makeGlobal(heard: "cuber netes", written: "Kubernetes")
        #expect(store.vocabulary().count == 1)
        #expect(store.vocabulary().first?.scope == .global)
        #expect(store.vocabulary().first?.uses == 3)
        #expect(store.vocabulary(for: .me).count == 1)
    }

    @Test func aMeetingIsWrittenWithEachSpeakersVocabulary() throws {
        let store = try makeStore()
        let fran = UUID()
        try store.learn(heard: "cuber", written: "Kubernetes", scope: .person(fran))
        try store.learn(heard: "yira", written: "Jira", scope: .me)
        let transcript = Transcript(startedAt: Date(), locale: "es_ES", source: "Teams", segments: [
            TranscriptSegment(channel: .others, start: 0, end: 1, text: "cuber y yira", speaker: "speaker-1",
                              words: [TimedWord(text: "cuber", start: 0, end: 0.5)]),
            TranscriptSegment(channel: .others, start: 1, end: 2, text: "cuber y yira", speaker: "speaker-2"),
            TranscriptSegment(channel: .me, start: 2, end: 3, text: "cuber y yira"),
        ])
        var meeting = MeetingRecord(title: "t", sourceApp: "Teams", startedAt: Date(), duration: 3, transcript: transcript)
        meeting.people = ["speaker-1": fran]
        let written = store.applyingVocabulary(to: meeting).transcript.segments
        #expect(written.map(\.text) == ["Kubernetes y yira", "cuber y yira", "cuber y Jira"])
        #expect(written[0].words.isEmpty)
    }
}
