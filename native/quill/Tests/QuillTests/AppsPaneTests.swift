import Foundation
import RewriteKit
import Testing

@testable import Quill

@Suite("Apps pane", .serialized)
@MainActor
struct AppsPaneTests {
    private func harness() throws -> (AppsPaneModel, SettingsStore, ProfileStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AppsPaneTests-\(UUID().uuidString)")
        let settings = SettingsStore(dataDirectory: folder)
        let profiles = ProfileStore(dataDirectory: folder)
        try profiles.seedIfEmpty(language: "en")
        let running = [AppsPaneModel.RunningApp(bundleIdentifier: "com.apple.mail", name: "Mail"),
                       AppsPaneModel.RunningApp(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")]
        let model = AppsPaneModel(settings: settings, profiles: profiles, runningApps: { running })
        model.reload()
        return (model, settings, profiles, folder)
    }

    @Test("an app added from the running ones gets a default; its profile and direct apply are kept")
    func mapping() throws {
        let (model, settings, _, folder) = try harness()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(model.addable.map(\.name) == ["Mail", "TextEdit"])
        model.add("com.apple.mail")
        #expect(model.rows.map(\.name) == ["Mail"])
        #expect(model.addable.map(\.name) == ["TextEdit"])

        let formal = try #require(model.profiles.first { $0.builtIn == .formal })
        model.setProfile(formal.id, for: "com.apple.mail")
        model.setAppliesDirectly(true, for: "com.apple.mail")
        let stored = try settings.settings()
        #expect(stored.appDefaults["com.apple.mail"] == formal.id)
        #expect(stored.directApplyApps == ["com.apple.mail"])

        model.remove("com.apple.mail")
        #expect(try settings.settings().appDefaults.isEmpty)
        #expect(try settings.settings().directApplyApps.isEmpty)
    }

    @Test("deleting a profile removes its mappings")
    func deletingProfileRemovesMapping() async throws {
        let (model, settings, profiles, folder) = try harness()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.add("com.apple.TextEdit")
        let mapped = try #require(model.rows.first?.profileID)
        let pane = ProfilesPaneModel(settings: settings, profiles: profiles,
                                     registry: try ProviderRegistryHolder(shipped: [], customServers: [], makeCustom: { _ in fatalError() }),
                                     catalog: FakeCatalog(), readiness: .empty, language: "en")
        await pane.reload()
        await pane.delete(mapped)
        model.reload()
        #expect(model.rows.isEmpty)
    }
}
