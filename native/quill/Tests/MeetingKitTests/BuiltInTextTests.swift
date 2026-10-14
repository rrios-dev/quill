import Foundation
import ListenKit
import SynthesisKit
import Testing
@testable import MeetingKit

/// Built-in roles and focuses read in the interface's language unless the user renamed them.
@Suite("Built-in text")
struct BuiltInTextTests {
    private func makeStore() throws -> (MeetingStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try MeetingStore(directory: root)
        store.builtInText = .init(
            roles: ["support": .init(name: "Support", detail: "Looks after the customers")],
            focuses: ["work": .init(name: "Product minutes", detail: "What was decided and who does what")]
        )
        return (store, root)
    }

    @Test("an untouched built-in is shown in the reader's language")
    func untouched() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.roles().first { $0.id == "support" }?.name == "Support")
        #expect(store.focuses().first { $0.id == "work" }?.name == "Product minutes")
        #expect(store.focuses().first { $0.id == "work" }?.objective == "What was decided and who does what")
    }

    @Test("a built-in the user renamed keeps their words")
    func renamed() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var roles = MeetingRole.defaults
        roles[2].name = "Atención al cliente"
        try store.saveRoles(roles)
        #expect(store.roles().first { $0.id == "support" }?.name == "Atención al cliente")
    }

    @Test("a saved synthesis of a built-in focus reads with today's name")
    func savedSynthesis() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let synthesis = SynthesisRecord(focusID: "work", focusName: SynthesisFocus.work.name, model: "m", text: "", participants: [])
        #expect(store.displayName(of: synthesis) == "Product minutes")
        let custom = SynthesisRecord(focusID: "mine", focusName: "Mi enfoque", model: "m", text: "", participants: [])
        #expect(store.displayName(of: custom) == "Mi enfoque")
    }
}
