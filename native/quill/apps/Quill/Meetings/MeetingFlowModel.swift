import AppKit
import Foundation
import ListenKit
import MeetingKit
import ModelKit
import Observation
import QuillSupport
import RewriteKit
import SynthesisKit
import Translation

/// One meeting's window: the people, the analysis and the transcript, all in view.
///
/// It used to be two steps — name the people, then synthesise — and the second one hid
/// the transcript and the people: the owner, on his first real meeting, named everyone,
/// pressed Continue and lost the meeting he was analysing (2026-10-08). Now nothing is a
/// step: the people are edited in place, the transcript stays at the side, and the
/// analysis is read against both.
@MainActor
@Observable
final class MeetingFlowModel {
    /// Where the window opens: on the people (just recorded, nobody named yet) or on the
    /// analysis. Only emphasis; everything stays reachable.
    enum Step: Equatable { case people, synthesis }

    /// Consecutive segments of one speaker, as the transcript pane shows them.
    struct Turn: Identifiable, Equatable {
        let id: Int
        let label: String
        let start: Double
        let end: Double
        let text: String
        /// The segments it is made of, each a sentence the user can give to another voice.
        var lines: [Line] = []
    }

    /// One segment of a turn: its index in the transcript's `segments`.
    struct Line: Identifiable, Equatable {
        var id: Int { index }
        let index: Int
        let text: String
        /// The others' channel: only those can be given to another voice.
        let movable: Bool
    }

    /// Sentences that sound like the ones the user just moved, offered to follow them
    /// (VOICES.md S1).
    struct Proposal: Equatable {
        let source: String
        let target: String
        let indices: [Int]
    }

    /// How much each voice took of the meeting.
    struct SpeakerStat: Identifiable, Equatable {
        var id: String { label }
        let label: String
        let seconds: Double
        let share: Double
        let turns: Int
    }

    struct PersonRow: Identifiable, Equatable {
        var id: String { label }
        let label: String
        let turns: Int
        let sample: String
        var name: String
        var roleID: String?
        /// The role came from the people directory, not from this meeting.
        var roleRemembered: Bool
        /// Someone the directory knows whose voice this sounds like, for an unnamed
        /// voice, proposed for the user to confirm (J-03).
        var suggestion: KnownPerson?
        /// For a named voice: someone else it sounds like, so one of the names is wrong.
        var soundsLike: KnownPerson?
        /// Two people of the directory heard in this one voice, offered to split (VOICES.md S5).
        var split: SplitOffer?
        /// The person this voice is, by id (J-02): set when the user confirms a proposal or
        /// picks among people who share the name, cleared when the name is changed.
        var personID: UUID?
        /// People the typed name may be, when it cannot tell by itself: several share it,
        /// or the voice is not the one person who has it (EFFICIENCY.md E4).
        var candidates: [KnownPerson] = []
    }

    /// "Here Fran and Hugo seem to speak": the voice keeps `kept`, `moved` go to `other`.
    struct SplitOffer: Equatable {
        let kept: KnownPerson
        let other: KnownPerson
        let moved: [Int]
    }

    /// A person of the directory, as a row proposes them.
    struct KnownPerson: Equatable {
        let id: UUID
        let name: String
        let roleID: String?
    }

    var step: Step
    private(set) var record: MeetingRecord
    var rows: [PersonRow] = []
    private(set) var roles: [MeetingRole] = []
    private(set) var focuses: [SynthesisFocus] = []
    var focusID: String
    /// Name → treatment, for this meeting only (MEETINGS.md §7.1).
    var overrides: [String: Treatment] = [:]
    var nuance = ""
    var modelChoice: SynthesisModelChoice
    private(set) var running = false
    private(set) var result: SynthesisRecord?
    private(set) var error: String?
    /// The provider that would receive the transcript for the first time.
    private(set) var consentProvider: String?
    /// The person whose turns the transcript shows alone, if any.
    var selectedLabel: String?
    var showsTranscript = true
    var transcriptQuery = ""
    /// A moment the transcript should scroll to (a tap on the timeline).
    private(set) var jumpTarget: (time: Double, serial: Int)?
    private(set) var turns: [Turn] = []
    /// Translating the transcript: not needed, waiting for Apple's language pack, or done.
    enum TranscriptTranslation: Equatable {
        case notNeeded
        case needsDownload(TranslationSession.Configuration)
        case working
        case ready
    }
    private(set) var transcriptTranslation: TranscriptTranslation = .notNeeded
    private(set) var stats: [SpeakerStat] = []
    private(set) var proposal: Proposal?
    /// What the last correction taught, said under the transcript until dismissed.
    private(set) var learnt: LearntNotice?
    /// Voice label → people its typed name may be, until the user chooses.
    private var choices: [String: [UUID]] = [:]
    /// Voices the user said are someone new, though the name is known.
    private var newPeople: Set<String> = []

    /// The words a correction added to someone's vocabulary (VOICES.md S3–S4).
    struct LearntNotice: Equatable {
        /// "cuber netes" → "Kubernetes", in order.
        let pairs: [Pair]
        /// Whose vocabulary: a person's name, the user's, or nil for everybody.
        let owner: String?
        /// Other sentences of the same voice corrected with it.
        let alsoCorrected: Int
        /// Pairs already kept for someone else: offered to everybody (J-04).
        let promotable: [Pair]
        /// Pairs whose heard word is an ordinary word of the language ("vale" → "Valle"):
        /// learnt only if the user says so, or every "vale" would change.
        let held: [Pair]
        fileprivate let sentence: Int
        fileprivate let previous: TranscriptSegment
        fileprivate let created: [UUID]

        struct Pair: Equatable, Hashable {
            let heard: String
            let written: String
        }
    }

    private let coordinator: MeetingsCoordinator
    private let log = QuillLog(category: "meeting-flow")

    init(record: MeetingRecord, coordinator: MeetingsCoordinator, step: Step) {
        self.record = record
        self.coordinator = coordinator
        self.step = step
        focusID = coordinator.preferences.defaultFocusID
        modelChoice = SynthesisModelChoice.matching(coordinator.preferences.modelSelection) ?? .fidelity
        reload()
        showLatestResult()
        Task { await translateTranscript() }
    }

    func translation(of turn: Turn) -> String? {
        guard record.translationLanguage == coordinator.preferences.translationLanguage.minimalIdentifier else { return nil }
        return record.translations?[turn.text]
    }

    /// Translates every turn not translated yet, in one batch, into the user's language.
    func translateTranscript() async {
        guard readerLanguage != nil else {
            transcriptTranslation = .notNeeded
            return
        }
        let source = Locale(identifier: record.transcript.locale).language
        let target = coordinator.preferences.translationLanguage
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: break
        case .supported:
            transcriptTranslation = .needsDownload(TranslationSession.Configuration(source: source, target: target))
            return
        default:
            transcriptTranslation = .notNeeded
            return
        }
        if record.translationLanguage != target.minimalIdentifier {
            record.translations = [:]
            record.translationLanguage = target.minimalIdentifier
        }
        let missing = Array(Set(turns.map(\.text).filter { record.translations?[$0] == nil }))
        guard !missing.isEmpty else {
            transcriptTranslation = .ready
            return
        }
        transcriptTranslation = .working
        let session = TranslationSession(installedSource: source, target: target)
        do {
            // One turn at a time, saved as it goes: a long meeting shows its first
            // translations at once instead of after the last.
            for (index, text) in missing.enumerated() {
                record.translations?[text] = try await session.translate(text).targetText
                if index % 20 == 19 { persist() }
            }
            persist()
        } catch {
            log.error("transcript translation failed: \(error)")
        }
        transcriptTranslation = .ready
    }

    private var store: MeetingStore { coordinator.store }

    func reload() {
        rebuildTranscript()
        roles = store.roles()
        focuses = store.focuses()
        if !focuses.contains(where: { $0.id == focusID }) { focusID = focuses.first?.id ?? "work" }
        let known = Dictionary(store.people().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let suggestions = store.suggestions(for: record)
        let conflicts = store.conflicts(for: record)
        let splits = store.splits(for: record)
        func knownPerson(_ id: UUID?) -> KnownPerson? {
            id.flatMap { known[$0] }.map { KnownPerson(id: $0.id, name: $0.name, roleID: $0.roleID) }
        }
        func knownPerson(_ suggestion: VoiceRecognition.Suggestion?) -> KnownPerson? { knownPerson(suggestion?.personID) }
        func offer(_ split: KnownSplit<UUID>?) -> SplitOffer? {
            guard let split, let kept = knownPerson(split.kept), let other = knownPerson(split.other) else { return nil }
            return SplitOffer(kept: kept, other: other, moved: split.moved)
        }
        rows = record.labels.map { label in
            let segments = record.transcript.segments.filter { ($0.speaker ?? $0.channel.rawValue) == label }
            let sample = segments.max { $0.text.count < $1.text.count }?.text ?? ""
            let personID = record.people[label]
            let person = personID.flatMap { known[$0] }
            let name = record.transcript.names[label] ?? person?.name ?? ""
            // A voice that holds two people is not proposed as either of them alone.
            let split = offer(splits[label])
            return PersonRow(label: label, turns: segments.count, sample: String(sample.prefix(110)),
                             name: name, roleID: person?.roleID, roleRemembered: person?.roleID != nil,
                             suggestion: name.isEmpty && split == nil ? knownPerson(suggestions[label]) : nil,
                             soundsLike: split != nil ? nil : knownPerson(conflicts[label].flatMap {
                                 (record.rejectedPeople?[label] ?? []).contains($0.personID) ? nil : $0
                             }),
                             split: split, personID: personID,
                             candidates: (choices[label] ?? []).compactMap { knownPerson($0) })
        }
    }

    var focus: SynthesisFocus { focuses.first { $0.id == focusID } ?? .work }

    var palette: MeetingPalette { MeetingPalette(record: record) }

    func focusName(of synthesis: SynthesisRecord) -> String { store.displayName(of: synthesis) }

    /// The user's language, in English, when the meeting was held in another one: the
    /// synthesis is written for its reader. Nil when they are the same.
    var readerLanguage: String? {
        let preferences = coordinator.preferences
        let meeting = Locale(identifier: record.transcript.locale).language.languageCode
        let reader = preferences.translationLanguage.languageCode
        guard let reader, meeting != reader else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: reader.identifier)
    }

    var document: SynthesisDocument? { result.map { SynthesisDocument(markdown: $0.text) } }

    /// Someone still has no name: the analysis would attribute their words to "Persona 2".
    var needsNames: Bool { rows.contains { $0.label != "me" && $0.name.trimmingCharacters(in: .whitespaces).isEmpty } }

    func displayName(for label: String) -> String {
        record.transcript.names[label] ?? defaultLabel(for: label)
    }

    func treatment(for label: String) -> Treatment? {
        participants.first { $0.name == palette.transcriptName(for: label) }?.treatment
    }

    func toggleSelection(_ label: String) {
        selectedLabel = selectedLabel == label ? nil : label
        if selectedLabel != nil { showsTranscript = true }
    }

    func jump(to time: Double) {
        showsTranscript = true
        selectedLabel = nil
        transcriptQuery = ""
        jumpTarget = (time, (jumpTarget?.serial ?? 0) + 1)
    }

    /// The turns the transcript pane shows, after the person and search filters.
    var visibleTurns: [Turn] {
        let query = transcriptQuery.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return turns.filter { turn in
            (selectedLabel == nil || turn.label == selectedLabel)
                && (query.isEmpty || turn.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    .contains(query))
        }
    }

    private func rebuildTranscript() {
        var merged: [Turn] = []
        let segments = record.transcript.segments
        let order = segments.indices.sorted { a, b in
            let lhs = segments[a], rhs = segments[b]
            return lhs.start == rhs.start ? lhs.channel == .me && rhs.channel != .me : lhs.start < rhs.start
        }
        for index in order {
            let segment = segments[index]
            let label = segment.speaker ?? segment.channel.rawValue
            let line = Line(index: index, text: segment.text, movable: segment.channel == .others)
            if let last = merged.last, last.label == label {
                merged[merged.count - 1] = Turn(id: last.id, label: label, start: last.start, end: max(last.end, segment.end),
                                                text: last.text + " " + segment.text, lines: last.lines + [line])
            } else {
                merged.append(Turn(id: merged.count, label: label, start: segment.start, end: segment.end, text: segment.text,
                                   lines: [line]))
            }
        }
        turns = merged
        var seconds: [String: Double] = [:]
        var counts: [String: Int] = [:]
        for turn in merged {
            seconds[turn.label, default: 0] += max(turn.end - turn.start, 0)
            counts[turn.label, default: 0] += 1
        }
        let total = max(seconds.values.reduce(0, +), 1)
        stats = record.labels.map { label in
            SpeakerStat(label: label, seconds: seconds[label] ?? 0, share: (seconds[label] ?? 0) / total,
                        turns: counts[label] ?? 0)
        }
    }

    // MARK: Who said it

    /// The voices a sentence can be given to: every other voice of the others' channel.
    func voiceChoices(excluding label: String) -> [String] {
        record.labels.filter { $0 != label && $0 != "me" && $0 != "others" }
    }

    /// "This was said by someone else": the sentence goes to `label`, or to a new voice
    /// when nil. From the second sentence a voice receives, the ones still under the old
    /// voice that sound like them are proposed (`Transcript.soundingLike`).
    func move(sentence index: Int, to label: String?) {
        guard record.transcript.segments.indices.contains(index),
              let source = record.transcript.segments[index].speaker else { return }
        commitPeople()
        let target = label ?? record.transcript.newVoiceLabel
        record.transcript.move([index], to: target)
        let likes = record.transcript.soundingLike(target, from: source)
        proposal = likes.isEmpty ? nil : Proposal(source: source, target: target, indices: likes)
        persist()
        reload()
    }

    func acceptProposal() {
        guard let proposal else { return }
        record.transcript.move(proposal.indices, to: proposal.target)
        self.proposal = nil
        persist()
        reload()
    }

    func dismissProposal() { proposal = nil }

    func isProposed(_ index: Int) -> Bool { proposal?.indices.contains(index) ?? false }

    /// Where the timeline ends: the recorded duration, or the last word when longer.
    var timelineLength: Double { max(record.duration, turns.last?.end ?? 0, 1) }

    /// The newest synthesis already made with the chosen focus, if any.
    func showLatestResult() {
        result = record.syntheses.last { $0.focusID == focusID }
    }

    func choose(focus id: String) {
        focusID = id
        overrides = [:]
        showLatestResult()
    }

    func defaultLabel(for label: String) -> String {
        if label == "me" { return MeetingCopy.t("label.me") }
        if label == "others" { return MeetingCopy.t("label.others") }
        let number = label.split(separator: "-").last.map(String.init) ?? label
        return String(localized: "label.person \(number)", bundle: .localized)
    }

    /// Typing a known name fills in the role remembered for it. A name changed away from
    /// the person the voice was tied to unties it: it is resolved again when committed.
    func nameChanged(at index: Int) {
        guard rows.indices.contains(index) else { return }
        if let id = rows[index].personID, let person = store.people().first(where: { $0.id == id }),
           MeetingStore.fold(person.name) != MeetingStore.fold(rows[index].name.trimmingCharacters(in: .whitespaces)) {
            rows[index].personID = nil
            newPeople.remove(rows[index].label)
        }
        guard rows[index].roleID == nil || rows[index].roleRemembered else { return }
        if let person = store.person(named: rows[index].name), let roleID = person.roleID {
            rows[index].roleID = roleID
            rows[index].roleRemembered = true
        }
    }

    // MARK: Corrections

    /// The user rewrote a sentence. The words that changed are learnt for whoever said it
    /// and written into their other sentences; an unnamed voice's wait on that voice and go
    /// to its person when it is named. A word the language already has ("vale" for
    /// "Valle") is not learnt unless the user says so: every "vale" would change.
    func correct(sentence index: Int, to text: String) {
        guard record.transcript.segments.indices.contains(index) else { return }
        let new = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segment = record.transcript.segments[index]
        guard !new.isEmpty, new != segment.text else { return }
        commitPeople()
        let label = segment.speaker ?? segment.channel.rawValue
        let scope = record.vocabularyScope(of: label)
        let pairs = Vocabulary.replacements(from: segment.text, to: new)
        let language = Locale(identifier: record.transcript.locale).language.languageCode?.identifier
        let held = pairs.filter { Self.isOrdinaryWord($0.heard, language: language) }
        let taught = pairs.filter { pair in !held.contains { $0 == pair } }
        record.transcript.segments[index].heard = segment.heard ?? segment.text
        record.transcript.segments[index].text = new
        record.transcript.segments[index].edited = true
        record.transcript.segments[index].words = []
        var created: [UUID] = []
        var promotable: [LearntNotice.Pair] = []
        for pair in taught {
            guard let learnt = try? store.learn(heard: pair.heard, written: pair.written, scope: scope) else { continue }
            if learnt.entry.uses == 1 { created.append(learnt.entry.id) }
            if !learnt.alsoFor.isEmpty { promotable.append(.init(heard: pair.heard, written: pair.written)) }
        }
        let before = record
        record = store.applyingVocabulary(to: record)
        if !pairs.isEmpty { coordinator.countUsage("corrections", pairs.count) }
        learnt = pairs.isEmpty ? nil : LearntNotice(
            pairs: taught.map { .init(heard: $0.heard, written: $0.written) },
            owner: owner(of: scope, label: label),
            alsoCorrected: changedSentences(from: before), promotable: promotable,
            held: held.map { .init(heard: $0.heard, written: $0.written) },
            sentence: index, previous: segment, created: created)
        persist()
        rebuildTranscript()
    }

    /// "Learn it anyway": the held words become vocabulary too.
    func learnHeld() {
        guard let notice = learnt, !notice.held.isEmpty else { return }
        let segment = record.transcript.segments[notice.sentence]
        let label = segment.speaker ?? segment.channel.rawValue
        let scope = record.vocabularyScope(of: label)
        var created = notice.created
        var promotable = notice.promotable
        for pair in notice.held {
            guard let learnt = try? store.learn(heard: pair.heard, written: pair.written, scope: scope) else { continue }
            if learnt.entry.uses == 1 { created.append(learnt.entry.id) }
            if !learnt.alsoFor.isEmpty { promotable.append(pair) }
        }
        let before = record
        record = store.applyingVocabulary(to: record)
        learnt = LearntNotice(pairs: notice.pairs + notice.held, owner: notice.owner,
                              alsoCorrected: notice.alsoCorrected + changedSentences(from: before),
                              promotable: promotable, held: [], sentence: notice.sentence,
                              previous: notice.previous, created: created)
        persist()
        rebuildTranscript()
    }

    /// Puts the sentence back and forgets what that correction alone had taught; the
    /// other sentences it had rewritten get the transcriber's words back.
    func undoCorrection() {
        guard let notice = learnt else { return }
        for id in notice.created { try? store.forgetVocabulary(id) }
        record.transcript.segments[notice.sentence] = notice.previous
        record = store.applyingVocabulary(to: record)
        learnt = nil
        persist()
        rebuildTranscript()
    }

    /// Whose vocabulary a scope is, as the notice says it: nil while the voice has no name.
    private func owner(of scope: VocabularyEntry.Scope, label: String) -> String? {
        if case .voice = scope { return nil }
        return displayName(for: label)
    }

    private func changedSentences(from before: MeetingRecord) -> Int {
        zip(before.transcript.segments, record.transcript.segments).filter { $0.text != $1.text }.count
    }

    /// A single word the language's dictionary knows: changing it everywhere would change
    /// sentences where it was right.
    static func isOrdinaryWord(_ word: String, language: String?) -> Bool {
        guard !word.contains(where: \.isWhitespace), word.count > 1 else { return false }
        let checker = NSSpellChecker.shared
        let available = language.flatMap { code in checker.availableLanguages.first { $0.hasPrefix(code) } }
        let misspelled = checker.checkSpelling(of: word, startingAt: 0, language: available, wrap: false,
                                               inSpellDocumentWithTag: 0, wordCount: nil)
        return misspelled.location == NSNotFound
    }

    /// "Use it for everybody": the correction kept for several people becomes global, and
    /// this meeting is written with it.
    func makeCorrectionGlobal() {
        guard let notice = learnt else { return }
        for pair in notice.promotable { try? store.makeGlobal(heard: pair.heard, written: pair.written) }
        record = store.applyingVocabulary(to: record)
        learnt = nil
        persist()
        rebuildTranscript()
    }

    func dismissLearnt() { learnt = nil }

    // MARK: Known voices

    /// "Fran · Product Owner", or the name alone.
    func personTitle(_ person: KnownPerson) -> String {
        guard let roleID = person.roleID, let role = roles.first(where: { $0.id == roleID }) else { return person.name }
        return person.name + " · " + role.name
    }

    /// The user confirms the proposal: the row takes the person's name and role, and their voice learns
    /// this meeting's.
    func acceptSuggestion(for label: String) {
        guard let index = rows.firstIndex(where: { $0.label == label }),
              let person = rows[index].suggestion ?? rows[index].soundsLike else { return }
        rows[index].name = person.name
        rows[index].roleID = person.roleID
        rows[index].roleRemembered = person.roleID != nil
        rows[index].personID = person.id
        commitPeople()
        reload()
        coordinator.countUsage("voices_recognised", 1)
    }

    /// The user picks which of the people with this name the voice is, or says it is
    /// someone new (`id` nil).
    func choosePerson(_ id: UUID?, for label: String) {
        guard let index = rows.firstIndex(where: { $0.label == label }) else { return }
        choices[label] = nil
        if let id, let person = store.people().first(where: { $0.id == id }) {
            rows[index].personID = id
            newPeople.remove(label)
            if rows[index].roleID == nil, let roleID = person.roleID {
                rows[index].roleID = roleID
                rows[index].roleRemembered = true
            }
        } else {
            rows[index].personID = nil
            newPeople.insert(label)
        }
        commitPeople()
        reload()
    }

    /// The user says it is someone else: not proposed again for this voice, and the samples that
    /// made Quill think so are forgotten — they were this voice under another name.
    func rejectSuggestion(for label: String) {
        guard let row = rows.first(where: { $0.label == label }),
              let person = row.suggestion ?? row.soundsLike else { return }
        var rejected = record.rejectedPeople ?? [:]
        rejected[label, default: []].append(person.id)
        record.rejectedPeople = rejected
        if row.suggestion != nil, let voice = VoiceRecognition.voices(of: record.transcript)[label] {
            try? store.unlearnVoice(like: voice, of: person.id)
        }
        persist()
        reload()
    }

    /// "Yes, they are two": the other person's sentences go to the voice already named as
    /// them in this meeting, or to a new one, and both voices take their person's name and
    /// role where they have none yet. Naming them teaches each person this meeting's voice.
    func acceptSplit(for label: String) {
        guard let offer = rows.first(where: { $0.label == label })?.split else { return }
        commitPeople()
        let target = record.people.first { $0.value == offer.other.id && $0.key != label }?.key
            ?? record.transcript.newVoiceLabel
        record.transcript.move(offer.moved, to: target)
        persist()
        reload()
        for (rowLabel, person) in [(label, offer.kept), (target, offer.other)] {
            guard let index = rows.firstIndex(where: { $0.label == rowLabel }),
                  rows[index].name.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            rows[index].name = person.name
            rows[index].roleID = person.roleID
            rows[index].roleRemembered = person.roleID != nil
            rows[index].personID = person.id
        }
        commitPeople()
        reload()
        coordinator.countUsage("voices_split", 1)
    }

    /// "No, it is not them": the second person is not proposed for this voice again.
    func rejectSplit(for label: String) {
        guard let offer = rows.first(where: { $0.label == label })?.split else { return }
        var rejected = record.rejectedPeople ?? [:]
        rejected[label, default: []].append(offer.other.id)
        record.rejectedPeople = rejected
        persist()
        reload()
    }

    /// Two voices given the same person are one person the diarizer split: the later
    /// voice's sentences join the first. Measured on the owner's meetings: "Fran" twice
    /// in one call, the two voices 0.62 alike. Two voices tied to two different people
    /// who share a name stay apart.
    private func mergeVoicesWithTheSameName() -> Bool {
        var first: [String: String] = [:]
        var moves: [(from: String, to: String)] = []
        for row in rows where row.label != "me" && row.label != "others" {
            let name = MeetingStore.fold(row.name.trimmingCharacters(in: .whitespaces))
            guard !name.isEmpty, !newPeople.contains(row.label), choices[row.label] == nil else { continue }
            let key = row.personID.map { "id:" + $0.uuidString } ?? "name:" + name
            if let target = first[key] { moves.append((row.label, target)) } else { first[key] = row.label }
        }
        guard !moves.isEmpty else { return false }
        for move in moves {
            let indices = record.transcript.segments.indices.filter { record.transcript.segments[$0].speaker == move.from }
            record.transcript.move(indices, to: move.to)
            record.transcript.names[move.from] = nil
            record.people[move.from] = nil
        }
        rows.removeAll { row in moves.contains { $0.from == row.label } }
        log.info("merged \(moves.count) voices named like another in the same meeting")
        return true
    }

    /// Names and roles go into the meeting and into the people directory, as they are
    /// typed: there is no separate step to confirm them.
    ///
    /// A label already tied to a person of the same name only changes that person's role;
    /// remembering them again would count the same meeting twice.
    func commitPeople() {
        let merged = mergeVoicesWithTheSameName()
        let known = Dictionary(store.people().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let voices = VoiceRecognition.voices(of: record.transcript)
        var names: [String: String] = [:]
        var people: [String: UUID] = [:]
        var waiting: [String: [UUID]] = [:]
        for index in rows.indices {
            let row = rows[index]
            let name = row.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            names[row.label] = name
            // Who the voice is: the person the user tied it to, the one the name and voice
            // point to, someone new, or a choice to make (EFFICIENCY.md E4).
            var personID = row.personID.flatMap { known[$0] == nil ? nil : $0 }
            if personID == nil, !newPeople.contains(row.label) {
                switch store.match(name: name, voice: voices[row.label]) {
                case .person(let id): personID = id
                case .new: break
                case .ambiguous(let ids):
                    waiting[row.label] = ids
                    continue
                }
            }
            if let personID, record.people[row.label] == personID {
                if known[personID]?.roleID != row.roleID { try? store.update(person: personID, roleID: row.roleID) }
                people[row.label] = personID
            } else if let person = try? store.remember(personID, name: name, roleID: row.roleID, at: record.startedAt) {
                people[row.label] = person.id
            }
            rows[index].personID = people[row.label]
            if people[row.label] != nil { newPeople.remove(row.label) }
        }
        if waiting != choices {
            choices = waiting
            for index in rows.indices {
                rows[index].candidates = (waiting[rows[index].label] ?? []).compactMap { known[$0] }
                    .map { KnownPerson(id: $0.id, name: $0.name, roleID: $0.roleID) }
            }
        }
        guard merged || names != record.transcript.names || people != record.people else { return }
        // Each named voice teaches its person what they sound like; a person who lost a
        // voice here forgets what they sounded like in this meeting.
        for (label, old) in record.people where people[label] != old {
            try? store.forgetVoice(of: old, in: record.id)
        }
        for (label, person) in people {
            if let voice = voices[label] { try? store.learnVoice(voice, of: person, in: record.id) }
            // What was corrected while the voice had no name is now its person's.
            try? store.adoptVocabulary(of: label, in: record.id, as: person)
        }
        record.transcript.names = names
        record.people = people
        // A voice that now has a person is written with that person's vocabulary.
        record = store.applyingVocabulary(to: record)
        persist()
        rebuildTranscript()
        Task { await translateTranscript() }
    }

    // MARK: Synthesis

    var participants: [Participant] {
        focus.weighting.participants(store.people(in: record), overrides: overrides)
    }

    func cycleOverride(for name: String) {
        let current = participants.first { $0.name == name }?.treatment ?? .influences
        let all = Treatment.allCases
        let next = all[(all.firstIndex(of: current)! + 1) % all.count]
        let base = focus.weighting.participants(store.people(in: record)).first { $0.name == name }?.treatment
        overrides[name] = next == base ? nil : next
    }

    func synthesize(consented: Bool = false) async {
        guard !running else { return }
        // A name still being typed counts: the synthesis must use it.
        commitPeople()
        error = nil
        let selection = modelChoice.selection
        let provider: any ModelProvider
        do {
            provider = try coordinator.environment.registry.current.provider(for: selection)
        } catch {
            self.error = MeetingCopy.t("synthesis.error.provider")
            return
        }
        let descriptor = provider.descriptor
        let settings = coordinator.environment.settings
        if ConsentRule.isRemote(descriptor, treatLoopbackAsRemote: false), !consented,
           !((try? settings.settings().notifiedProviders.contains(descriptor.id)) ?? false) {
            consentProvider = descriptor.displayName
            return
        }
        if consented {
            _ = try? settings.update { $0.notifiedProviders.insert(descriptor.id) }
            consentProvider = nil
        }

        running = true
        defer { running = false }
        var focus = self.focus
        let nuance = self.nuance.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nuance.isEmpty {
            focus.notes += (focus.notes.isEmpty ? "" : "\n") + "For this synthesis only: \(nuance)"
        }
        let participants = self.participants
        let context = try? await provider.models().first { $0.id == selection.model }?.contextTokens
        do {
            let outcome = try await Synthesizer(provider: provider, model: selection.model, contextTokens: context ?? nil)
                .synthesize(transcript: record.transcript.rendered(), focus: focus, participants: participants,
                            outputLanguage: readerLanguage)
            let synthesis = SynthesisRecord(
                focusID: focus.id, focusName: focus.name,
                model: "\(selection.provider.rawValue):\(selection.model.rawValue)",
                text: outcome.text, participants: participants,
                truncated: outcome.finishReason == .length, isDraft: modelChoice.isDraft
            )
            record.syntheses.append(synthesis)
            result = synthesis
            persist()
            coordinator.countUsage("syntheses", 1)
            coordinator.countUsage(QuillUsage.provider(selection.provider.rawValue), 1)
        } catch {
            log.error("synthesis failed: \(error)")
            self.error = MeetingCopy.t("synthesis.error.failed")
        }
    }

    func declineConsent() { consentProvider = nil }

    func openFocusEditor() { coordinator.openFocusEditor() }

    /// The window follows a new name.
    @ObservationIgnored var onRenamed: (String) -> Void = { _ in }

    /// A name of the user's own for the meeting, from its window or the history.
    func rename(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != record.title else { return }
        record.title = trimmed
        persist()
        onRenamed(trimmed)
        coordinator.countUsage("meetings_renamed", 1)
    }

    private func persist() {
        do {
            try store.save(record)
        } catch {
            log.error("could not save the meeting: \(error)")
        }
        coordinator.meetingChanged()
    }
}
