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
        rows = record.labels.map { label in
            let segments = record.transcript.segments.filter { ($0.speaker ?? $0.channel.rawValue) == label }
            let sample = segments.max { $0.text.count < $1.text.count }?.text ?? ""
            let personID = record.people[label]
            let person = personID.flatMap { known[$0] }
            let name = record.transcript.names[label] ?? person?.name ?? ""
            return PersonRow(label: label, turns: segments.count, sample: String(sample.prefix(110)),
                             name: name, roleID: person?.roleID, roleRemembered: person?.roleID != nil)
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
        for segment in record.transcript.ordered {
            let label = segment.speaker ?? segment.channel.rawValue
            if let last = merged.last, last.label == label {
                merged[merged.count - 1] = Turn(id: last.id, label: label, start: last.start, end: max(last.end, segment.end),
                                                text: last.text + " " + segment.text)
            } else {
                merged.append(Turn(id: merged.count, label: label, start: segment.start, end: segment.end, text: segment.text))
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

    /// Typing a known name fills in the role remembered for it.
    func nameChanged(at index: Int) {
        guard rows.indices.contains(index), rows[index].roleID == nil || rows[index].roleRemembered else { return }
        if let person = store.person(named: rows[index].name), let roleID = person.roleID {
            rows[index].roleID = roleID
            rows[index].roleRemembered = true
        }
    }

    /// Names and roles go into the meeting and into the people directory, as they are
    /// typed: there is no separate step to confirm them.
    ///
    /// A label already tied to a person of the same name only changes that person's role;
    /// remembering them again would count the same meeting twice.
    func commitPeople() {
        let known = Dictionary(store.people().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var names: [String: String] = [:]
        var people: [String: UUID] = [:]
        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            names[row.label] = name
            if let linked = record.people[row.label], let person = known[linked],
               store.person(named: name)?.id == person.id {
                if person.roleID != row.roleID { try? store.update(person: linked, roleID: row.roleID) }
                people[row.label] = linked
            } else if let person = try? store.remember(name: name, roleID: row.roleID, at: record.startedAt) {
                people[row.label] = person.id
            }
        }
        guard names != record.transcript.names || people != record.people else { return }
        record.transcript.names = names
        record.people = people
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
        } catch {
            log.error("synthesis failed: \(error)")
            self.error = MeetingCopy.t("synthesis.error.failed")
        }
    }

    func declineConsent() { consentProvider = nil }

    func openFocusEditor() { coordinator.openFocusEditor() }

    func rename(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        record.title = trimmed
        persist()
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
