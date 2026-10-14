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

    public init(directory: URL) throws {
        self.directory = directory
        try fileManager.createDirectory(at: meetingsDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
    }

    var meetingsDirectory: URL { directory.appendingPathComponent("meetings", isDirectory: true) }
    var peopleFile: URL { directory.appendingPathComponent("people.json") }
    var rolesFile: URL { directory.appendingPathComponent("roles.json") }
    var focusesFile: URL { directory.appendingPathComponent("focuses.json") }

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

    public func forget(person id: UUID) throws {
        try write(people().filter { $0.id != id }, to: peopleFile)
    }

    // MARK: Roles and focuses

    public func roles() -> [MeetingRole] {
        read([MeetingRole].self, from: rolesFile) ?? MeetingRole.defaults
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
        return builtIns + custom.filter { !builtInIDs.contains($0.id) }
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
