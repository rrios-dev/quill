import Foundation
import ListenKit
import Testing

@testable import MeetingKit

/// Lists and searches read `index.json`, and the index follows what is on disk even when
/// another process wrote it (EFFICIENCY.md E3).
@Suite("Meeting index", .serialized)
struct MeetingIndexTests {
    private func makeStore(_ root: URL) throws -> MeetingStore { try MeetingStore(directory: root) }

    private func meeting(_ title: String, at seconds: Double, text: String = "Hola") -> MeetingRecord {
        let date = Date(timeIntervalSince1970: seconds)
        return MeetingRecord(title: title, sourceApp: "Zoom", startedAt: date, duration: 60,
                             transcript: Transcript(startedAt: date, locale: "es_ES", source: "zoom", segments: [
                                 TranscriptSegment(channel: .others, start: 0, end: 2, text: text, speaker: "speaker-1"),
                             ]))
    }

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("quill-index-\(UUID().uuidString)")
    }

    @Test("a meeting saved by another store shows up in this one's list and search")
    func otherProcessWrites() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try makeStore(directory), agent = try makeStore(directory)
        try app.save(meeting("Primera", at: 1_000))
        #expect(agent.summaries().map(\.title) == ["Primera"])

        try app.save(meeting("Segunda", at: 2_000, text: "El presupuesto de diciembre"))
        #expect(agent.summaries().map(\.title) == ["Segunda", "Primera"])
        #expect(agent.search("PRESUPUESTO").map(\.title) == ["Segunda"])
    }

    @Test("an edited meeting is indexed again; a deleted one leaves the index")
    func editsAndDeletes() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try makeStore(directory), agent = try makeStore(directory)
        var record = meeting("Antes", at: 1_000)
        try app.save(record)
        #expect(agent.search("presupuesto").isEmpty)

        record.title = "Después"
        record.transcript.segments[0].text = "Hablamos del presupuesto, por fin"
        try app.save(record)
        #expect(agent.search("presupuesto").map(\.title) == ["Después"])

        try app.delete(record.id)
        #expect(agent.summaries().isEmpty)
    }

    @Test("an index from another version or a damaged one is rebuilt from the meetings")
    func rebuilds() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeStore(directory).save(meeting("Guardada", at: 1_000))
        let index = directory.appendingPathComponent("index.json")
        try Data("not json".utf8).write(to: index)
        #expect(try makeStore(directory).summaries().map(\.title) == ["Guardada"])
        try FileManager.default.removeItem(at: index)
        #expect(try makeStore(directory).summaries().map(\.title) == ["Guardada"])
    }

    @Test("the index is owner-only, like the transcripts it quotes")
    func ownerOnly() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeStore(directory).save(meeting("Privada", at: 1_000))
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("index.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
