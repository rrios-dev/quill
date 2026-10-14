import Foundation
import ListenKit
import SynthesisKit
import Testing

@testable import MeetingKit

@Suite("Meeting store", .serialized)
struct MeetingStoreTests {
    private func makeStore() throws -> (MeetingStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-meetings-\(UUID().uuidString)")
        return (try MeetingStore(directory: root), root)
    }

    private func meeting(_ title: String, startedAt: Date, text: String = "Hola") -> MeetingRecord {
        MeetingRecord(
            title: title, sourceApp: "Microsoft Teams", startedAt: startedAt, duration: 60,
            transcript: Transcript(startedAt: startedAt, locale: "es_ES", source: "teams", segments: [
                TranscriptSegment(channel: .me, start: 0, end: 1, text: text),
                TranscriptSegment(channel: .others, start: 2, end: 3, text: "Vale", speaker: "speaker-1"),
            ])
        )
    }

    @Test("a meeting round-trips, owner-only, newest first")
    func roundTrip() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let older = meeting("Antes", startedAt: Date(timeIntervalSince1970: 1_000))
        let newer = meeting("Después", startedAt: Date(timeIntervalSince1970: 2_000))
        try store.save(older)
        try store.save(newer)

        #expect(store.meetings().map(\.title) == ["Después", "Antes"])
        #expect(store.meeting(older.id) == older)
        let file = store.meetingsDirectory.appendingPathComponent("\(older.id.uuidString).json").path
        let mode = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int
        #expect(mode == 0o600, "a transcript readable by other accounts")
    }

    @Test("purging keeps what is within the retention and deletes the rest")
    func purge() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        try store.save(meeting("Reciente", startedAt: now.addingTimeInterval(-10 * 86_400)))
        try store.save(meeting("Vieja", startedAt: now.addingTimeInterval(-91 * 86_400)))

        #expect(try store.purge(olderThan: 90, now: now) == 1)
        #expect(store.meetings().map(\.title) == ["Reciente"])
    }

    @Test("search ignores case and accents and needs every word")
    func search() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(meeting("Producto", startedAt: Date(), text: "La migración del sábado"))
        try store.save(meeting("Cliente", startedAt: Date(), text: "Presupuesto"))

        #expect(store.search("MIGRACION sabado").map(\.title) == ["Producto"])
        #expect(store.search("migracion presupuesto").isEmpty)
    }

    @Test("a person is remembered once, with their role, whatever the accents")
    func people() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try store.remember(name: "Lucía", roleID: "tech-lead")
        let again = try store.remember(name: "lucia", roleID: nil)

        #expect(store.people().count == 1)
        #expect(again.roleID == "tech-lead", "a nil role must keep the known one")
        #expect(again.meetings == 2)
    }

    @Test("a channel that heard much less than the meeting lasted is reported silent")
    func silentChannels() {
        func record(_ captured: [String: Double]?, duration: Double = 600) -> MeetingRecord {
            MeetingRecord(title: "t", sourceApp: "Teams", startedAt: Date(), duration: duration,
                          transcript: Transcript(startedAt: Date(), locale: "es_ES", source: "teams"),
                          capturedSeconds: captured)
        }
        // The first real call: the others' capture never delivered, the microphone died at 2:18.
        #expect(record(["others": 0, "me": 138]).silentChannels == [.others, .me])
        #expect(record(["others": 598, "me": 597]).silentChannels.isEmpty)
        #expect(record(["others": 598]).silentChannels.isEmpty, "no microphone is not a silent microphone")
        #expect(record(nil).silentChannels.isEmpty, "older meetings did not keep it")
        #expect(record(["others": 0], duration: 12).silentChannels.isEmpty, "too short to judge")
    }

    @Test("a meeting saved before capturedSeconds existed still opens")
    func olderRecordsDecode() throws {
        let original = MeetingRecord(title: "t", sourceApp: "Teams", startedAt: Date(timeIntervalSince1970: 0), duration: 60,
                                     transcript: Transcript(startedAt: Date(timeIntervalSince1970: 0), locale: "es_ES", source: "teams"))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "capturedSeconds")
        let decoded = try JSONDecoder().decode(MeetingRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.capturedSeconds == nil)
        #expect(decoded.title == "t")
    }

    @Test("changing a role later does not count another meeting")
    func updatingARole() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let lucia = try store.remember(name: "Lucía", roleID: "tech-lead")
        try store.update(person: lucia.id, roleID: "product-owner")
        try store.update(person: lucia.id, roleID: nil)

        let stored = try #require(store.people().first)
        #expect(stored.meetings == 1)
        #expect(stored.roleID == nil, "editing can clear a role, unlike remembering")
    }

    @Test("participants carry the role their person is remembered with")
    func participantsTakeRememberedRoles() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let lucia = try store.remember(name: "Lucía", roleID: "tech-lead")
        var record = meeting("Producto", startedAt: Date())
        record.transcript.names = ["me": "Roberto", "speaker-1": "Lucía"]
        record.people = ["speaker-1": lucia.id]

        let people = store.people(in: record)
        #expect(people.map(\.name) == ["Roberto", "Lucía"])
        #expect(people.map(\.role?.id) == [nil, "tech-lead"])
    }

    @Test("a tuned built-in focus replaces the built-in; deleting history keeps roles and focuses")
    func focusesAndHistory() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var tuned = SynthesisFocus.work
        tuned.objective = "Solo lo técnico"
        try store.saveFocus(tuned)
        try store.saveRoles([MeetingRole(id: "x", name: "X", summary: "x")])
        try store.save(meeting("Producto", startedAt: Date()))
        try store.remember(name: "Lucía", roleID: "x")

        #expect(store.focuses().first?.objective == "Solo lo técnico")
        #expect(store.focuses().count == SynthesisFocus.builtIns.count)
        try store.deleteHistory()
        #expect(store.meetings().isEmpty)
        #expect(store.people().isEmpty)
        #expect(store.roles().map(\.id) == ["x"])
        #expect(store.focuses().first?.objective == "Solo lo técnico")
    }
}
