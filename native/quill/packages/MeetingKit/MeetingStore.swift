import Foundation
import ListenKit
import SynthesisKit

/// Meetings, people, roles and focuses on disk, under Quill's data folder:
///
///     meetings/<id>.json   one meeting: transcript, who was who, syntheses
///     people.json          names with their usual role
///     roles.json           the role catalogue (defaults until the user edits it)
///     focuses.json         the user's own focuses (built-ins live in code)
///
/// Files are owner-only (0600), like Ámbar's history: transcripts are other people's
/// words. Writes are atomic. Not thread-safe by itself: the app uses it from the main
/// actor.
public final class MeetingStore: @unchecked Sendable {
    public let directory: URL
    private let fileManager = FileManager.default

    /// The built-in roles and focuses in the reader's language, keyed by id.
    ///
    /// Built-ins are data the user can edit, written in Spanish where they are defined;
    /// an English reader saw "Soporte" and "Acta de producto" (2026-10-14). A built-in
    /// the user has not renamed is shown with these; one they renamed keeps their words.
    public struct BuiltInText: Sendable {
        public struct Entry: Sendable {
            public let name: String
            public let detail: String
            public init(name: String, detail: String) {
                self.name = name
                self.detail = detail
            }
        }

        public var roles: [String: Entry]
        public var focuses: [String: Entry]

        public init(roles: [String: Entry] = [:], focuses: [String: Entry] = [:]) {
            self.roles = roles
            self.focuses = focuses
        }

        /// The app's names for the built-ins, from a string table with the
        /// `role.builtin.*` and `focus.builtin.*` keys — the app's own, which the agent
        /// server inside the same bundle reads too.
        public init(strings bundle: Bundle) {
            func entry(_ key: String, _ detail: String) -> Entry {
                Entry(name: bundle.localizedString(forKey: key, value: nil, table: nil),
                      detail: bundle.localizedString(forKey: key + detail, value: nil, table: nil))
            }
            self.init(
                roles: [
                    "product-owner": entry("role.builtin.productOwner", ".summary"),
                    "tech-lead": entry("role.builtin.techLead", ".summary"),
                    "support": entry("role.builtin.support", ".summary"),
                    "engineer": entry("role.builtin.engineer", ".summary"),
                    "client": entry("role.builtin.client", ".summary"),
                    "vendor": entry("role.builtin.vendor", ".summary"),
                ],
                focuses: [
                    "work": entry("focus.builtin.work", ".objective"),
                    "analysis": entry("focus.builtin.analysis", ".objective"),
                    "brief": entry("focus.builtin.brief", ".objective"),
                ]
            )
        }
    }

    public var builtInText = BuiltInText()

    public init(directory: URL) throws {
        self.directory = directory
        try fileManager.createDirectory(at: meetingsDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
    }

    var meetingsDirectory: URL { directory.appendingPathComponent("meetings", isDirectory: true) }
    var peopleFile: URL { directory.appendingPathComponent("people.json") }
    var rolesFile: URL { directory.appendingPathComponent("roles.json") }
    var focusesFile: URL { directory.appendingPathComponent("focuses.json") }
    var vocabularyFile: URL { directory.appendingPathComponent("vocabulary.json") }

    // MARK: Meetings

    public func save(_ meeting: MeetingRecord) throws {
        try write(meeting, to: meetingsDirectory.appendingPathComponent("\(meeting.id.uuidString).json"))
    }

    public func meeting(_ id: UUID) -> MeetingRecord? {
        read(MeetingRecord.self, from: meetingsDirectory.appendingPathComponent("\(id.uuidString).json"))
    }

    /// Newest first.
    public func meetings() -> [MeetingRecord] {
        let files = (try? fileManager.contentsOfDirectory(at: meetingsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { read(MeetingRecord.self, from: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func summaries() -> [MeetingSummary] {
        meetings().map {
            MeetingSummary(id: $0.id, title: $0.title, sourceApp: $0.sourceApp, startedAt: $0.startedAt,
                           duration: $0.duration, peopleCount: $0.labels.count, synthesisCount: $0.syntheses.count)
        }
    }

    public func delete(_ id: UUID) throws {
        let url = meetingsDirectory.appendingPathComponent("\(id.uuidString).json")
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    /// Deletes every meeting and the people learnt from them. Roles and focuses stay:
    /// they are the user's settings, not meeting content.
    public func deleteHistory() throws {
        for meeting in meetings() { try delete(meeting.id) }
        if fileManager.fileExists(atPath: peopleFile.path) { try fileManager.removeItem(at: peopleFile) }
    }

    /// Deletes meetings that started more than `days` days before `now`. Returns how many.
    @discardableResult
    public func purge(olderThan days: Int, now: Date = Date()) throws -> Int {
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        let old = meetings().filter { $0.startedAt < limit }
        for meeting in old { try delete(meeting.id) }
        return old.count
    }

    /// Meetings whose title, transcript, names or syntheses contain every word of
    /// `query`, ignoring case and accents. Newest first.
    public func search(_ query: String) -> [MeetingRecord] {
        let words = query.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
        guard !words.isEmpty else { return meetings() }
        return meetings().filter { meeting in
            let text = Self.fold(meeting.searchableText)
            return words.allSatisfy { text.contains($0) }
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: People

    public func people() -> [Person] {
        read([Person].self, from: peopleFile) ?? []
    }

    /// The person with this name, compared ignoring case and accents.
    public func person(named name: String) -> Person? {
        let key = Self.fold(name.trimmingCharacters(in: .whitespaces))
        return people().first { Self.fold($0.name) == key }
    }

    /// Remembers that `name` took part in a meeting, with `roleID` when given (a nil role
    /// keeps the one already known). Returns the person.
    @discardableResult
    public func remember(name: String, roleID: String?, at date: Date = Date()) throws -> Person {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var all = people()
        let key = Self.fold(trimmed)
        if let index = all.firstIndex(where: { Self.fold($0.name) == key }) {
            all[index].meetings += 1
            all[index].lastSeen = date
            if let roleID { all[index].roleID = roleID }
            try write(all, to: peopleFile)
            return all[index]
        }
        let person = Person(name: trimmed, roleID: roleID, meetings: 1, lastSeen: date)
        all.append(person)
        try write(all, to: peopleFile)
        return person
    }

    /// Changes the role of someone already remembered, without counting another meeting:
    /// what editing the people of a meeting that was already saved does.
    public func update(person id: UUID, roleID: String?) throws {
        var all = people()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].roleID = roleID
        try write(all, to: peopleFile)
    }

    /// Samples a person keeps: the most recent meetings win.
    public static let voiceSamplesPerPerson = 12

    /// Keeps `voiceprint` as what `person` sounded like in `meeting`, replacing what was
    /// kept for that meeting before.
    public func learnVoice(_ voiceprint: Voiceprint, of person: UUID, in meeting: UUID) throws {
        var all = people()
        guard let index = all.firstIndex(where: { $0.id == person }) else { return }
        var voices = (all[index].voices ?? []).filter { $0.meetingID != meeting }
        voices.append(VoiceSample(meetingID: meeting, voiceprint: voiceprint))
        all[index].voices = Array(voices.suffix(Self.voiceSamplesPerPerson))
        try write(all, to: peopleFile)
    }

    /// "This is not them": forgets the samples of `person` that sound like `voiceprint`
    /// (`VoiceRecognition.sameVoice`). They came from a meeting where another voice was
    /// given this person's name, and they are why the proposal was made.
    public func unlearnVoice(like voiceprint: Voiceprint, of person: UUID) throws {
        var all = people()
        guard let index = all.firstIndex(where: { $0.id == person }), let voices = all[index].voices else { return }
        let kept = voices.filter { VoiceRecognition.cosine($0.voiceprint.values, voiceprint.values) < VoiceRecognition.sameVoice }
        guard kept.count != voices.count else { return }
        all[index].voices = kept
        try write(all, to: peopleFile)
    }

    /// Learns the voices of people already named in saved meetings that kept voiceprints
    /// (1.2.0 on): the directory starts out recognising them. Meetings already learnt are
    /// skipped, so it can run at every launch. Returns how many samples were added.
    @discardableResult
    public func learnVoicesFromHistory() throws -> Int {
        var all = people()
        var added = 0
        for meeting in meetings() {
            let voices = VoiceRecognition.voices(of: meeting.transcript)
            for (label, personID) in meeting.people {
                guard let voice = voices[label], let index = all.firstIndex(where: { $0.id == personID }),
                      !(all[index].voices ?? []).contains(where: { $0.meetingID == meeting.id }) else { continue }
                all[index].voices = Array(((all[index].voices ?? []) + [VoiceSample(meetingID: meeting.id, voiceprint: voice)])
                    .suffix(Self.voiceSamplesPerPerson))
                added += 1
            }
        }
        if added > 0 { try write(all, to: peopleFile) }
        return added
    }

    /// Who each unnamed voice of `meeting` may be (`VoiceRecognition.suggestions`).
    public func suggestions(for meeting: MeetingRecord) -> [String: VoiceRecognition.Suggestion] {
        VoiceRecognition.suggestions(voices: VoiceRecognition.voices(of: meeting.transcript), people: people(),
                                     named: meeting.people, rejected: meeting.rejectedPeople ?? [:])
    }

    /// Named voices of `meeting` that sound like someone else (`VoiceRecognition.conflicts`).
    public func conflicts(for meeting: MeetingRecord) -> [String: VoiceRecognition.Suggestion] {
        VoiceRecognition.conflicts(voices: VoiceRecognition.voices(of: meeting.transcript), people: people(),
                                   named: meeting.people, in: meeting.id)
    }

    /// Forgets what `person` sounded like in `meeting`: the voice there was not them.
    public func forgetVoice(of person: UUID, in meeting: UUID) throws {
        var all = people()
        guard let index = all.firstIndex(where: { $0.id == person }) else { return }
        all[index].voices = all[index].voices?.filter { $0.meetingID != meeting }
        try write(all, to: peopleFile)
    }

    public func forget(person id: UUID) throws {
        try write(people().filter { $0.id != id }, to: peopleFile)
    }

    // MARK: Vocabulary

    public func vocabulary() -> [VocabularyEntry] {
        read([VocabularyEntry].self, from: vocabularyFile) ?? []
    }

    /// What a correction taught, for the interface to say so.
    public struct Learnt: Equatable, Sendable {
        public let entry: VocabularyEntry
        /// The same correction is already kept for someone else: it can go global (J-04).
        public let alsoFor: [VocabularyEntry.Scope]
    }

    /// Keeps `heard` → `written` for whoever said it; the same correction again counts
    /// once more. Returns what was kept.
    @discardableResult
    public func learn(heard: String, written: String, scope: VocabularyEntry.Scope, at date: Date = Date()) throws -> Learnt {
        var all = vocabulary()
        let entry: VocabularyEntry
        if let index = all.firstIndex(where: { $0.scope == scope && $0.same(as: heard, written) })
            ?? all.firstIndex(where: { $0.scope == .global && $0.same(as: heard, written) }) {
            all[index].uses += 1
            entry = all[index]
        } else {
            entry = VocabularyEntry(heard: heard, written: written, scope: scope, createdAt: date)
            all.append(entry)
        }
        try write(all, to: vocabularyFile)
        let others = all.filter { $0.id != entry.id && $0.scope != .global && $0.same(as: heard, written) }.map(\.scope)
        return Learnt(entry: entry, alsoFor: entry.scope == .global ? [] : others)
    }

    /// Makes a correction kept for several people one for everybody.
    public func makeGlobal(heard: String, written: String) throws {
        var all = vocabulary()
        let matching = all.filter { $0.same(as: heard, written) }
        guard !matching.isEmpty else { return }
        all.removeAll { $0.same(as: heard, written) }
        all.append(VocabularyEntry(heard: heard, written: written, scope: .global,
                                   uses: matching.map(\.uses).reduce(0, +),
                                   createdAt: matching.map(\.createdAt).min() ?? Date()))
        try write(all, to: vocabularyFile)
    }

    public func forgetVocabulary(_ id: UUID) throws {
        try write(vocabulary().filter { $0.id != id }, to: vocabularyFile)
    }

    /// The entries that apply to words said by `scope`: everybody's and their own.
    public func vocabulary(for scope: VocabularyEntry.Scope?) -> [VocabularyEntry] {
        vocabulary().filter { $0.scope == .global || (scope != nil && $0.scope == scope) }
    }

    /// `meeting` with the vocabulary written into every sentence, each by the entries of
    /// whoever said it. Changed sentences lose their word timings, which no longer match.
    public func applyingVocabulary(to meeting: MeetingRecord) -> MeetingRecord {
        let all = vocabulary()
        guard !all.isEmpty else { return meeting }
        var result = meeting
        for index in result.transcript.segments.indices {
            let segment = result.transcript.segments[index]
            let label = segment.speaker ?? segment.channel.rawValue
            let scope = meeting.vocabularyScope(of: label)
            let entries = all.filter { $0.scope == .global || (scope != nil && $0.scope == scope) }
            let text = Vocabulary.apply(entries, to: segment.text)
            if text != segment.text {
                result.transcript.segments[index].text = text
                result.transcript.segments[index].words = []
            }
        }
        return result
    }

    // MARK: Roles and focuses

    public func roles() -> [MeetingRole] {
        (read([MeetingRole].self, from: rolesFile) ?? MeetingRole.defaults).map(localized)
    }

    private func localized(_ role: MeetingRole) -> MeetingRole {
        guard let text = builtInText.roles[role.id],
              let original = MeetingRole.defaults.first(where: { $0.id == role.id }),
              role.name == original.name, role.summary == original.summary else { return role }
        return MeetingRole(id: role.id, name: text.name, summary: text.detail)
    }

    private func localized(_ focus: SynthesisFocus) -> SynthesisFocus {
        guard let text = builtInText.focuses[focus.id],
              let original = SynthesisFocus.builtIns.first(where: { $0.id == focus.id }),
              focus.name == original.name else { return focus }
        var shown = focus
        shown.name = text.name
        if focus.objective == original.objective { shown.objective = text.detail }
        return shown
    }

    /// What a saved synthesis's focus is called now: a built-in's name in the reader's
    /// language, else the name it had when it was made.
    public func displayName(of synthesis: SynthesisRecord) -> String {
        guard let original = SynthesisFocus.builtIns.first(where: { $0.id == synthesis.focusID }),
              synthesis.focusName == original.name, let text = builtInText.focuses[synthesis.focusID] else {
            return synthesis.focusName
        }
        return text.name
    }

    public func saveRoles(_ roles: [MeetingRole]) throws {
        try write(roles, to: rolesFile)
    }

    /// Built-ins first, then the user's own; a stored focus with a built-in's id replaces
    /// it (the user tuned it).
    public func focuses() -> [SynthesisFocus] {
        let custom = read([SynthesisFocus].self, from: focusesFile) ?? []
        let tuned = Dictionary(custom.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let builtIns = SynthesisFocus.builtIns.map { tuned[$0.id] ?? $0 }
        let builtInIDs = Set(SynthesisFocus.builtIns.map(\.id))
        return (builtIns + custom.filter { !builtInIDs.contains($0.id) }).map(localized)
    }

    public func saveFocus(_ focus: SynthesisFocus) throws {
        var custom = read([SynthesisFocus].self, from: focusesFile) ?? []
        custom.removeAll { $0.id == focus.id }
        custom.append(focus)
        try write(custom, to: focusesFile)
    }

    public func deleteFocus(_ id: String) throws {
        let custom = (read([SynthesisFocus].self, from: focusesFile) ?? []).filter { $0.id != id }
        try write(custom, to: focusesFile)
    }

    // MARK: Participants

    /// Who took part in `meeting`, with their remembered roles: what a synthesis weighs.
    public func people(in meeting: MeetingRecord) -> [(name: String, role: MeetingRole?)] {
        let catalogue = Dictionary(roles().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Dictionary(people().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return meeting.labels.map { label in
            let segment = TranscriptSegment(channel: label == "me" ? .me : .others, start: 0, end: 0, text: "",
                                            speaker: label == "me" || label == "others" ? nil : label)
            let name = meeting.transcript.label(for: segment)
            let role = meeting.people[label].flatMap { known[$0]?.roleID }.flatMap { catalogue[$0] }
            return (name, role)
        }
    }

    // MARK: Files

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(value).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
