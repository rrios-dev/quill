import Foundation
import ListenKit
import MeetingKit

/// `meeting-bench history [--meetings N]` (EFFICIENCY.md E3): a history of N one-hour
/// meetings, the size the owner's longest ones are, timed the way the history window and
/// the agent tools read it — every meeting decoded, as before the index, and the index
/// cold (built from the files) and warm (a new process reading it).
enum HistoryBench {
    static func run(meetings count: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quill-history-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let words = ["presupuesto", "migración", "cliente", "entrega", "jueves", "revisamos", "el", "de", "que", "la",
                     "equipo", "sprint", "despliegue", "factura", "proveedor", "reunión", "mañana", "vale", "pues", "bueno"]
        var generator = SystemRandomNumberGenerator()
        let writer = try MeetingStore(directory: directory)
        for number in 0..<count {
            let start = Date(timeIntervalSince1970: 1_700_000_000 + Double(number) * 86_400)
            let segments = (0..<600).map { index -> TranscriptSegment in
                let text = (0..<14).map { _ in words.randomElement(using: &generator)! }.joined(separator: " ")
                return TranscriptSegment(channel: index % 4 == 0 ? .me : .others, start: Double(index) * 6,
                                         end: Double(index) * 6 + 5, text: text,
                                         speaker: index % 4 == 0 ? nil : "speaker-\(index % 3 + 1)",
                                         voiceprint: index % 4 == 0 ? nil : Voiceprint((0..<256).map { _ in Float.random(in: -1...1) }))
            }
            try writer.save(MeetingRecord(title: "Reunión \(number)", sourceApp: "Microsoft Teams", startedAt: start,
                                          duration: 3_600, transcript: Transcript(startedAt: start, locale: "es_ES",
                                                                                  source: "teams", segments: segments)))
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("meetings"),
                                                                includingPropertiesForKeys: [.fileSizeKey])
        let bytes = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        let index = directory.appendingPathComponent("index.json")
        let indexBytes = (try? index.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        print(String(format: "%d meetings, %.0f MB on disk, index %.1f MB", count, Double(bytes) / 1e6, Double(indexBytes) / 1e6))

        func time(_ label: String, _ body: () -> Int) {
            let began = ContinuousClock.now
            let result = body()
            let took = ContinuousClock.now - began
            print(String(format: "%@: %.0f ms (%d)", label, Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1000, result))
        }
        time("every meeting decoded (before)") {
            let store = try! MeetingStore(directory: directory)
            return store.summaries().compactMap { store.meeting($0.id) }.count
        }
        try FileManager.default.removeItem(at: index)
        time("list, index cold (first launch)") { try! MeetingStore(directory: directory).summaries().count }
        time("list, index warm (new process)") { try! MeetingStore(directory: directory).summaries().count }
        time("search, index warm (new process)") { try! MeetingStore(directory: directory).search("presupuesto jueves").count }
        let store = try MeetingStore(directory: directory)
        _ = store.summaries()
        time("search again, same store (history window)") { store.search("factura proveedor").count }
    }
}
