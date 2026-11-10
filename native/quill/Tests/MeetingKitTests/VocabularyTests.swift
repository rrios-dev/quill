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
        // The word timings stay: they belong to what was heard, which is kept beside it.
        #expect(written[0].heard == "cuber y yira")
        #expect(written[0].words.count == 1)
        #expect(written[1].heard == nil, "a sentence the vocabulary left alone keeps no copy")
    }
}

/// The dictionary keeps what the transcriber wrote, waits on unnamed voices and lets a
/// word go cleanly (EFFICIENCY.md E4).
@Suite("Vocabulary that can be taken back", .serialized)
struct ReversibleVocabularyTests {
    private func makeStore() throws -> MeetingStore {
        try MeetingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private func meeting(_ segments: [TranscriptSegment], people: [String: UUID] = [:]) -> MeetingRecord {
        MeetingRecord(title: "Daily", sourceApp: "Teams", startedAt: Date(timeIntervalSince1970: 1_000), duration: 60,
                      transcript: Transcript(startedAt: Date(), locale: "es_ES", source: "teams", segments: segments),
                      people: people)
    }

    @Test func forgettingAWordGivesBackWhatTheTranscriberWrote() throws {
        let store = try makeStore()
        let entry = try store.learn(heard: "cuber netes", written: "Kubernetes", scope: .global).entry
        var record = store.applyingVocabulary(to: meeting([
            TranscriptSegment(channel: .others, start: 0, end: 2, text: "Lo subimos a cuber netes", speaker: "speaker-1"),
        ]))
        #expect(record.transcript.segments[0].text == "Lo subimos a Kubernetes")
        #expect(record.transcript.segments[0].heard == "Lo subimos a cuber netes")
        try store.save(record)

        #expect(try store.forgetVocabulary(entry.id) == 1)
        record = try #require(store.meeting(record.id))
        #expect(record.transcript.segments[0].text == "Lo subimos a cuber netes")
        #expect(record.transcript.segments[0].heard == nil)
    }

    @Test func aSentenceRewrittenByHandIsLeftAsWritten() throws {
        let store = try makeStore()
        let entry = try store.learn(heard: "yira", written: "Jira", scope: .global).entry
        let record = meeting([
            TranscriptSegment(channel: .me, start: 0, end: 2, text: "Abre el yira, por favor", heard: "abre el yira", edited: true),
        ])
        #expect(store.applyingVocabulary(to: record) == record)
        try store.save(record)
        #expect(try store.forgetVocabulary(entry.id) == 0)
        #expect(store.meeting(record.id)?.transcript.segments[0].text == "Abre el yira, por favor")
    }

    @Test func aCorrectionToAnUnnamedVoiceWaitsForItsPerson() throws {
        let store = try makeStore()
        var record = meeting([
            TranscriptSegment(channel: .others, start: 0, end: 2, text: "Mira el yira", speaker: "speaker-2"),
            TranscriptSegment(channel: .others, start: 3, end: 5, text: "El yira de ayer", speaker: "speaker-3"),
        ])
        let scope = record.vocabularyScope(of: "speaker-2")
        #expect(scope == .voice(meeting: record.id, label: "speaker-2"))
        try store.learn(heard: "yira", written: "Jira", scope: scope)
        record = store.applyingVocabulary(to: record)
        #expect(record.transcript.segments.map(\.text) == ["Mira el Jira", "El yira de ayer"], "another voice is not this one")

        let fran = try store.remember(nil, name: "Fran", roleID: nil)
        try store.adoptVocabulary(of: "speaker-2", in: record.id, as: fran.id)
        #expect(store.vocabulary().map(\.scope) == [.person(fran.id)])
        #expect(store.pendingVocabulary().isEmpty)
    }

    @Test func deletingAMeetingDropsWhatWaitedOnItsVoices() throws {
        let store = try makeStore()
        let record = meeting([TranscriptSegment(channel: .others, start: 0, end: 2, text: "Hola", speaker: "speaker-1")])
        try store.save(record)
        try store.learn(heard: "yira", written: "Jira", scope: record.vocabularyScope(of: "speaker-1"))
        try store.learn(heard: "cuber", written: "Kubernetes", scope: .me)
        try store.delete(record.id)
        #expect(store.vocabulary().map(\.written) == ["Kubernetes"])
    }

    @Test func aWordAddedByHandFixesTheMeetingsAlreadyKept() throws {
        let store = try makeStore()
        let record = meeting([TranscriptSegment(channel: .me, start: 0, end: 2, text: "Abre el yira")])
        try store.save(record)
        var entry = try store.setVocabulary(VocabularyEntry(heard: "yira", written: "Jira", scope: .me))
        #expect(store.meeting(record.id)?.transcript.segments[0].text == "Abre el Jira")
        entry.written = "Jira Cloud"
        try store.setVocabulary(entry)
        #expect(store.meeting(record.id)?.transcript.segments[0].text == "Abre el Jira Cloud")
        #expect(store.meeting(record.id)?.transcript.segments[0].heard == "Abre el yira")
    }

    @Test func anEntryWrittenByHandIsOneEntryPerOwner() throws {
        let store = try makeStore()
        let fran = UUID()
        let first = try store.setVocabulary(VocabularyEntry(heard: " cuber ", written: "Kubernetes", scope: .person(fran)))
        #expect(first.heard == "cuber")
        var edited = first
        edited.written = "Kubernetes (K8s)"
        try store.setVocabulary(edited)
        #expect(store.vocabulary().map(\.written) == ["Kubernetes (K8s)"])
        try store.setVocabulary(VocabularyEntry(heard: "", written: "nada", scope: .global))
        #expect(store.vocabulary().count == 1, "an empty entry is not kept")
    }
}

/// Two people may share a name; a person is their id (J-02, EFFICIENCY.md E4).
@Suite("People by id", .serialized)
struct PeopleByIDTests {
    private func makeStore() throws -> MeetingStore {
        try MeetingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    private let franVoice = Voiceprint([1, 0, 0]), otherVoice = Voiceprint([0, 1, 0])

    @Test func aNewNameIsANewPersonAndTheSameNameAgainIsThem() throws {
        let store = try makeStore()
        #expect(store.match(name: "Fran", voice: nil) == .new)
        let fran = try store.remember(name: "Fran", roleID: "product-owner")
        #expect(store.match(name: "fran", voice: nil) == .person(fran.id))
        #expect(store.match(name: "Fran", voice: franVoice) == .person(fran.id), "a person never heard is not contradicted")
    }

    @Test func aVoiceThatIsNotThemAsksInsteadOfMerging() throws {
        let store = try makeStore()
        let fran = try store.remember(name: "Fran", roleID: nil)
        try store.learnVoice(franVoice, of: fran.id, in: UUID())
        #expect(store.match(name: "Fran", voice: franVoice) == .person(fran.id))
        #expect(store.match(name: "Fran", voice: otherVoice) == .ambiguous([fran.id]))
    }

    @Test func twoFransAreTwoPeopleAndTheVoiceTellsThemApart() throws {
        let store = try makeStore()
        let first = try store.remember(name: "Fran", roleID: nil)
        let second = try store.remember(nil, name: "Fran", roleID: "client")
        #expect(first.id != second.id)
        #expect(store.people(named: "Fran").count == 2)
        #expect(store.person(named: "Fran") == nil, "no single person answers to a shared name")
        #expect(store.match(name: "Fran", voice: nil) == .ambiguous([first.id, second.id]))
        try store.learnVoice(otherVoice, of: second.id, in: UUID())
        #expect(store.match(name: "Fran", voice: otherVoice) == .person(second.id))
        #expect(store.match(name: "Fran", voice: franVoice) == .ambiguous([first.id, second.id]))
        let again = try store.remember(second.id, name: "Fran", roleID: nil)
        #expect(again.meetings == 2)
        #expect(store.people().count == 2)
    }
}
