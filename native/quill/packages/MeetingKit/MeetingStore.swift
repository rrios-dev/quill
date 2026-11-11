import Foundation
import ListenKit
import SynthesisKit

/// Meetings, people, roles and focuses on disk, under Quill's data folder:
///
///     meetings/<id>.json   one meeting: transcript, who was who, syntheses
///     index.json           what lists and searches read instead of every meeting
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
    /// The index as last read or written by this store (`index.json`).
    private var index: [UUID: MeetingIndexEntry]?

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
                    "weekly": entry("focus.builtin.weekly", ".objective"),
                    "client": entry("focus.builtin.client", ".objective"),
                    "mine": entry("focus.builtin.mine", ".objective"),
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
    var indexFile: URL { directory.appendingPathComponent("index.json") }

    // MARK: Meetings

    public func save(_ meeting: MeetingRecord) throws {
        let url = meetingsDirectory.appendingPathComponent("\(meeting.id.uuidString).json")
        try write(meeting, to: url)
        var entries = currentIndex()
        if let stamp = stamp(of: url) {
            entries[meeting.id] = MeetingIndexEntry(meeting, stamp: stamp)
            storeIndex(entries)
        }
    }

    public func meeting(_ id: UUID) -> MeetingRecord? {
        read(MeetingRecord.self, from: meetingsDirectory.appendingPathComponent("\(id.uuidString).json"))
    }

    /// Every meeting, decoded. Newest first. Costly with a long history: lists and
    /// searches read `summaries()` and `search(_:)`, which use the index.
    public func meetings() -> [MeetingRecord] {
        summaries().compactMap { meeting($0.id) }
    }

    /// The most recent meeting, decoding only that one.
    public func latestMeeting() -> MeetingRecord? {
        summaries().first.flatMap { meeting($0.id) }
    }

    /// The name the user gave their own voice in their most recent meeting where they gave
    /// one, looking back at most `limit` meetings. A synthesis needs it when this meeting's
    /// own voice is still "Yo" or was not captured, so the user's own focus recognises
    /// them when others address them by name.
    public func ownName(limit: Int = 20) -> String? {
        for summary in summaries().prefix(limit) {
            guard let name = meeting(summary.id)?.transcript.names["me"]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != "Yo" else { continue }
            return name
        }
        return nil
    }

    /// Newest first, from the index: no transcript is decoded unless it changed since it
    /// was indexed.
    public func summaries() -> [MeetingSummary] {
        currentIndex().values.map(\.summary).sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(_ id: UUID) throws {
        let url = meetingsDirectory.appendingPathComponent("\(id.uuidString).json")
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        var entries = currentIndex()
        if entries.removeValue(forKey: id) != nil { storeIndex(entries) }
        // Corrections still waiting on a voice of this meeting go with it.
        let vocabulary = self.vocabulary()
        let kept = vocabulary.filter { entry in
            if case .voice(let meeting, _) = entry.scope { return meeting != id }
            return true
        }
        if kept.count != vocabulary.count { try write(kept, to: vocabularyFile) }
    }

    /// Deletes every meeting and the people learnt from them. Roles and focuses stay:
    /// they are the user's settings, not meeting content.
    public func deleteHistory() throws {
        for meeting in summaries() { try delete(meeting.id) }
        if fileManager.fileExists(atPath: peopleFile.path) { try fileManager.removeItem(at: peopleFile) }
    }

    /// Deletes meetings that started more than `days` days before `now`. Returns how many.
    @discardableResult
    public func purge(olderThan days: Int, now: Date = Date()) throws -> Int {
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        let old = summaries().filter { $0.startedAt < limit }
        for meeting in old { try delete(meeting.id) }
        return old.count
    }

    /// Meetings whose title, transcript, names or syntheses contain every word of
    /// `query`, ignoring case and accents. Newest first; read from the index.
    public func search(_ query: String) -> [MeetingSummary] {
        let words = query.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
        let entries = currentIndex().values.sorted { $0.summary.startedAt > $1.summary.startedAt }
        guard !words.isEmpty else { return entries.map(\.summary) }
        return entries.filter { entry in words.allSatisfy { entry.searchText.contains($0) } }.map(\.summary)
    }

    // MARK: Index

    /// The index, checked against the meetings on disk: a meeting written or deleted by
    /// another process (the agent server, an older version) is indexed again, by its
    /// file's size and date, and only that one is decoded.
    private func currentIndex() -> [UUID: MeetingIndexEntry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = ((try? fileManager.contentsOfDirectory(at: meetingsDirectory, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.pathExtension == "json" }
        var known = index ?? read(MeetingIndex.self, from: indexFile).map { file in
            file.version == MeetingIndex.version
                ? Dictionary(file.entries.map { ($0.summary.id, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        } ?? [:]
        var changed = false
        var present: Set<UUID> = []
        for url in files {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), let stamp = stamp(of: url) else { continue }
            present.insert(id)
            if known[id]?.stamp == stamp { continue }
            changed = true
            if let record = read(MeetingRecord.self, from: url) {
                known[id] = MeetingIndexEntry(record, stamp: stamp)
            } else {
                known[id] = nil
            }
        }
        for id in known.keys where !present.contains(id) {
            known[id] = nil
            changed = true
        }
        if changed || index == nil {
            if changed { storeIndex(known) } else { index = known }
        }
        return known
    }

    private func storeIndex(_ entries: [UUID: MeetingIndexEntry]) {
        index = entries
        // An index that cannot be written is rebuilt on the next read; nothing is lost.
        try? write(MeetingIndex(entries: Array(entries.values)), to: indexFile)
    }

    private func stamp(of url: URL) -> MeetingIndexEntry.Stamp? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate else { return nil }
        return MeetingIndexEntry.Stamp(size: size, modified: date.timeIntervalSince1970)
    }

    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: People

    public func people() -> [Person] {
        read([Person].self, from: peopleFile) ?? []
    }

    /// The people with this name, compared ignoring case and accents: more than one when
    /// two people share a name (J-02: a person is their id, never their name).
    public func people(named name: String) -> [Person] {
        let key = Self.fold(name.trimmingCharacters(in: .whitespaces))
        return people().filter { Self.fold($0.name) == key }
    }

    /// The only person with this name, if exactly one has it.
    public func person(named name: String) -> Person? {
        let matches = people(named: name)
        return matches.count == 1 ? matches.first : nil
    }

    /// Who a name typed for a voice is: someone the directory knows, a new person, or one
    /// of several the user must choose between.
    public enum PersonMatch: Equatable, Sendable {
        case new
        case person(UUID)
        case ambiguous([UUID])
    }

    /// Resolves a typed name with what the voice sounds like (EFFICIENCY.md E4).
    ///
    /// Nobody by that name: a new person. One person, and the voice does not clearly
    /// belong to someone else: them — the usual case, Fran again. When the voice is
    /// measured and the person's samples say it is not them (below
    /// `VoiceRecognition.threshold`), or several people share the name and the voice does
    /// not single one out, the user chooses: two Frans are two people.
    public func match(name: String, voice: Voiceprint?) -> PersonMatch {
        let matches = people(named: name)
        guard !matches.isEmpty else { return .new }
        if let voice {
            let heard = matches.filter { !($0.voices ?? []).isEmpty }
            let close = heard.map { ($0.id, VoiceRecognition.similarity(voice, to: $0)) }
                .filter { $0.1 >= VoiceRecognition.threshold }
                .sorted { $0.1 > $1.1 }
            if let best = close.first { return .person(best.0) }
            let unheard = matches.filter { ($0.voices ?? []).isEmpty }
            if unheard.count == 1, heard.isEmpty { return .person(unheard[0].id) }
            return .ambiguous(matches.map(\.id))
        }
        return matches.count == 1 ? .person(matches[0].id) : .ambiguous(matches.map(\.id))
    }

    /// Remembers that a person took part in a meeting: `id` when the voice is tied to
    /// someone already known, else a new person called `name`. A nil role keeps the one
    /// already known. Returns the person.
    @discardableResult
    public func remember(_ id: UUID?, name: String, roleID: String?, at date: Date = Date()) throws -> Person {
        var all = people()
        if let id, let index = all.firstIndex(where: { $0.id == id }) {
            all[index].meetings += 1
            all[index].lastSeen = date
            if let roleID { all[index].roleID = roleID }
            try write(all, to: peopleFile)
            return all[index]
        }
        let person = Person(name: name.trimmingCharacters(in: .whitespaces), roleID: roleID, meetings: 1, lastSeen: date)
        all.append(person)
        try write(all, to: peopleFile)
        return person
    }

    /// Remembers `name` the way a typed name with no voice resolves (`match`): the one
    /// person by that name, else a new one.
    @discardableResult
    public func remember(name: String, roleID: String?, at date: Date = Date()) throws -> Person {
        if case .person(let id) = match(name: name, voice: nil) {
            return try remember(id, name: name, roleID: roleID, at: date)
        }
        return try remember(nil, name: name, roleID: roleID, at: date)
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
        // Only meetings with a named person who has no sample from them yet are read.
        let pending = currentIndex().values.filter { entry in
            entry.people.contains { personID in
                all.first { $0.id == personID }.map { !($0.voices ?? []).contains { $0.meetingID == entry.summary.id } } ?? false
            }
        }
        for meeting in pending.compactMap({ meeting($0.summary.id) }) {
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

    /// Voices of `meeting` that hold two people of the directory (`VoiceRecognition.splits`).
    public func splits(for meeting: MeetingRecord) -> [String: KnownSplit<UUID>] {
        VoiceRecognition.splits(transcript: meeting.transcript, people: people(), named: meeting.people,
                                rejected: meeting.rejectedPeople ?? [:], in: meeting.id)
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
        // Only people count towards "everybody": a voice not named yet is nobody so far.
        let others = all.filter { $0.id != entry.id && $0.scope.isSomeone && $0.same(as: heard, written) }.map(\.scope)
        return Learnt(entry: entry, alsoFor: entry.scope.isSomeone ? others : [])
    }

    /// Adds an entry written by hand (Settings), or changes one: the same correction for
    /// the same owner is one entry. Returns it.
    /// Saved meetings are written with it at once, so a word added in Settings also
    /// fixes the meetings already kept.
    @discardableResult
    public func setVocabulary(_ entry: VocabularyEntry) throws -> VocabularyEntry {
        var all = vocabulary()
        let previous = all.first { $0.id == entry.id }
        let heard = entry.heard.trimmingCharacters(in: .whitespaces), written = entry.written.trimmingCharacters(in: .whitespaces)
        guard !heard.isEmpty, !written.isEmpty else { return entry }
        var kept = entry
        kept.heard = heard
        kept.written = written
        all.removeAll { $0.id == entry.id }
        if let index = all.firstIndex(where: { $0.scope == kept.scope && $0.same(as: heard, written) }) {
            all[index].uses += 1
            kept = all[index]
        } else {
            all.append(kept)
        }
        try write(all, to: vocabularyFile)
        try rewriteMeetings(containing: heard)
        if let previous { try rewriteMeetings(containing: previous.written) }
        return kept
    }

    /// Writes again, with the vocabulary as it is now, the meetings whose text contains
    /// `text`: the only ones an entry with those words can change. Returns how many changed.
    @discardableResult
    func rewriteMeetings(containing text: String) throws -> Int {
        var rewritten = 0
        for summary in search(text) {
            guard let meeting = meeting(summary.id) else { continue }
            let written = applyingVocabulary(to: meeting)
            if written != meeting {
                try save(written)
                rewritten += 1
            }
        }
        return rewritten
    }

    /// A voice was named: what was corrected while it had no name becomes its person's.
    public func adoptVocabulary(of label: String, in meeting: UUID, as person: UUID) throws {
        let pending = VocabularyEntry.Scope.voice(meeting: meeting, label: label)
        var all = vocabulary()
        guard all.contains(where: { $0.scope == pending }) else { return }
        for entry in all where entry.scope == pending {
            if let index = all.firstIndex(where: { $0.scope == .person(person) && $0.same(as: entry.heard, entry.written) }) {
                all[index].uses += entry.uses
            } else {
                var moved = entry
                moved.scope = .person(person)
                all.append(moved)
            }
        }
        all.removeAll { $0.scope == pending }
        try write(all, to: vocabularyFile)
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

    /// Forgets an entry and gives back what the transcriber wrote wherever it had changed
    /// it, except in sentences the user rewrote by hand. Returns the meetings rewritten.
    @discardableResult
    public func forgetVocabulary(_ id: UUID) throws -> Int {
        let all = vocabulary()
        guard let entry = all.first(where: { $0.id == id }) else { return 0 }
        try write(all.filter { $0.id != id }, to: vocabularyFile)
        // Only meetings that contain the corrected words can hold a sentence it changed.
        return try rewriteMeetings(containing: entry.written)
    }

    /// The entries that apply to words said by `scope`: everybody's and their own.
    public func vocabulary(for scope: VocabularyEntry.Scope?) -> [VocabularyEntry] {
        vocabulary().filter { $0.scope == .global || (scope != nil && $0.scope == scope) }
    }

    /// Corrections still waiting on an unnamed voice, from every meeting.
    public func pendingVocabulary() -> [VocabularyEntry] {
        vocabulary().filter { if case .voice = $0.scope { return true } else { return false } }
    }

    /// `meeting` with the vocabulary written into every sentence, each by the entries of
    /// whoever said it, always from what the transcriber wrote (`heard`): an entry
    /// forgotten since gives its words back. Sentences the user rewrote stay as written.
    public func applyingVocabulary(to meeting: MeetingRecord) -> MeetingRecord {
        let all = vocabulary()
        var result = meeting
        for index in result.transcript.segments.indices {
            let segment = result.transcript.segments[index]
            guard segment.edited != true else { continue }
            let scope = meeting.vocabularyScope(of: segment.speaker ?? segment.channel.rawValue)
            let base = segment.heard ?? segment.text
            let entries = all.filter { $0.scope == .global || $0.scope == scope }
            let text = entries.isEmpty ? base : Vocabulary.apply(entries, to: base)
            result.transcript.segments[index].text = text
            result.transcript.segments[index].heard = text == base ? nil : base
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
