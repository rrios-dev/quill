import Foundation
import ModelKit
import RewriteKit
import Testing

@testable import Quill

@MainActor
private final class ProfilesHarness {
    let folder: URL
    let settings: SettingsStore
    let store: ProfileStore
    let local = FakeProvider(id: "apple.on-device", name: "Apple Intelligence", onDevice: true, context: 4_096)
    let hosted = FakeProvider(id: "openrouter", name: "OpenRouter", onDevice: false, context: nil)
    let pane: ProfilesPaneModel

    init(readiness: ReadinessIndex = .empty) async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfilesPaneTests-\(UUID().uuidString)", isDirectory: true)
        settings = SettingsStore(dataDirectory: folder)
        store = ProfileStore(dataDirectory: folder)
        try store.seedIfEmpty(language: "en")
        try settings.update { $0.globalModel = ModelSelection(provider: "apple.on-device", model: "system") }
        let holder = try ProviderRegistryHolder(shipped: [local, hosted], customServers: [], makeCustom: { _ in fatalError() })
        pane = ProfilesPaneModel(settings: settings, profiles: store, registry: holder, catalog: FakeCatalog(),
                                 readiness: readiness, language: "en")
        await pane.reload()
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func select(_ builtIn: BuiltInProfile) async throws {
        let id = try #require(pane.profiles.first { $0.builtIn == builtIn }?.id)
        await pane.select(id)
    }
}

@Suite("Profiles pane", .serialized)
@MainActor
struct ProfilesPaneTests {
    @Test("an edit creates a version; revert restores it")
    func editAndRevert() async throws {
        let harness = try await ProfilesHarness()
        try await harness.select(.work)
        let original = try #require(harness.pane.draft)
        harness.pane.draft?.guidance = "Keep it short."
        #expect(harness.pane.hasChanges)
        await harness.pane.save()
        #expect(harness.pane.draft?.version == original.version + 1)
        #expect(harness.pane.versions.map(\.version) == [original.version])
        #expect(harness.pane.differences(from: harness.pane.versions[0]) == ["guidance"])

        await harness.pane.revert(to: original.version)
        #expect(harness.pane.draft?.guidance == original.guidance)
        #expect(harness.pane.draft?.version == original.version + 2)
    }

    @Test("an invalid draft is refused with its reason, and nothing is saved")
    func invalidDraft() async throws {
        let harness = try await ProfilesHarness()
        try await harness.select(.work)
        harness.pane.draft?.name = ""
        await harness.pane.save()
        #expect(harness.pane.problem == .nameEmpty)
        #expect(harness.pane.versions.isEmpty)
    }

    @Test("Try it shows G6 on a sample that triggers it, beside the previous version's result")
    func tryItSignals() async throws {
        let harness = try await ProfilesHarness()
        try await harness.select(.work)
        harness.pane.addSample("the meeting is moved to friday")
        harness.local.reply = "Hello there! The meeting has moved to Friday."
        #expect(await harness.pane.tryIt() == .ran)
        let sample = try #require(harness.pane.samples.samples.first)
        let result = try #require(harness.pane.tryItResults[sample.id])
        #expect(result.flags.contains(.addedGreeting), "\(result.flags)")
        #expect(sample.currentResult?.text == "Hello there! The meeting has moved to Friday.")

        // After an edit, the next run keeps the old result as the previous version's.
        harness.pane.draft?.guidance = "No greetings."
        await harness.pane.save()
        harness.local.reply = "The meeting has moved to Friday."
        await harness.pane.tryIt()
        let rerun = try #require(harness.pane.samples.samples.first)
        #expect(rerun.previousResult?.text == "Hello there! The meeting has moved to Friday.")
        #expect(rerun.currentResult?.text == "The meeting has moved to Friday.")
    }

    @Test("Try it goes through consent before sending samples to a new hosted recipient")
    func tryItConsent() async throws {
        let harness = try await ProfilesHarness()
        try await harness.select(.work)
        harness.pane.draft?.model = ModelSelection(provider: "openrouter", model: "vendor/model")
        await harness.pane.save()
        harness.pane.addSample("the meeting is moved to friday")
        guard case .needsConsent(let notice) = await harness.pane.tryIt() else { Issue.record("no consent asked"); return }
        #expect(notice.provider == "openrouter")
        #expect(harness.hosted.streamInputs.isEmpty, "nothing is sent before consent")
        harness.pane.declineTryItConsent()
        #expect(harness.hosted.streamInputs.isEmpty)

        await harness.pane.tryIt()
        await harness.pane.acceptTryItConsent()
        #expect(harness.hosted.streamInputs.count == 1)
        #expect(try harness.settings.settings().notifiedProviders.contains("openrouter"))
        #expect(await harness.pane.tryIt() == .ran, "accepted once, not asked again")
    }

    @Test("restoring brings back only the deleted built-ins")
    func restore() async throws {
        let harness = try await ProfilesHarness()
        try await harness.select(.formal)
        let formal = try #require(harness.pane.selectedID)
        try await harness.select(.work)
        harness.pane.draft?.guidance = "Mine."
        await harness.pane.save()
        await harness.pane.delete(formal)
        #expect(harness.pane.profiles.count == BuiltInProfile.shipped.count - 1)
        #expect(await harness.pane.restoreBuiltIns() == 1)
        #expect(harness.pane.profiles.count == BuiltInProfile.shipped.count)
        #expect(harness.pane.profiles.first { $0.builtIn == .work }?.guidance == "Mine.")
        #expect(await harness.pane.restoreBuiltIns() == 0)
    }

    @Test("deleting a profile removes its app mappings")
    func deleteForgetsMappings() async throws {
        let harness = try await ProfilesHarness()
        try await harness.select(.friends)
        let friends = try #require(harness.pane.selectedID)
        try harness.settings.update { $0.appDefaults["com.example.chat"] = friends }
        await harness.pane.delete(friends)
        #expect(try harness.settings.settings().appDefaults.isEmpty)
    }

    @Test("guidance past 60 words is marked not sent to small models; examples with identifiers are marked")
    func marks() async throws {
        let harness = try await ProfilesHarness()
        try await harness.select(.work)
        harness.pane.draft?.guidance = Array(repeating: "word", count: 80).joined(separator: " ")
        await harness.pane.addExample(input: "write to ana@example.org", output: "Write to ana@example.org.")
        await harness.pane.updateMarks()
        #expect(harness.pane.marks.guidanceSentWords == 60)
        let example = try #require(harness.pane.draft?.examples.last)
        #expect(harness.pane.marks.notSentForPersonalData.contains(example.id))
        #expect(harness.pane.findings(example) == [.email])

        await harness.pane.standIns(for: example)
        let neutral = try #require(harness.pane.draft?.examples.last)
        #expect(harness.pane.findings(neutral).isEmpty)
        #expect(!harness.pane.marks.notSentForPersonalData.contains(neutral.id))
    }

    @Test("deleting an example purges it from every version")
    func deleteExample() async throws {
        let harness = try await ProfilesHarness()
        try await harness.select(.work)
        await harness.pane.addExample(input: "see u", output: "See you.")
        await harness.pane.save()
        harness.pane.draft?.guidance = "Edit."
        await harness.pane.save()
        let example = try #require(harness.pane.draft?.examples.last)
        await harness.pane.deleteExample(example.id)
        #expect(harness.pane.draft?.examples.contains { $0.id == example.id } == false)
        #expect(harness.pane.versions.allSatisfy { !$0.examples.contains { $0.id == example.id } })
    }

    @Test("an edited built-in reads not evaluated (edited)")
    func readiness() async throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../tools/QuillBench/data/readiness.json").standardizedFileURL
        let harness = try await ProfilesHarness(readiness: try ReadinessIndex(data: Data(contentsOf: file)))
        try await harness.select(.work)
        harness.pane.draft?.guidance += " Mine."
        #expect(await harness.pane.readiness() == .notEvaluatedEdited)
    }

    @Test("an exported profile imports as a new one")
    func exportImport() async throws {
        let harness = try await ProfilesHarness()
        try await harness.select(.work)
        harness.pane.addSample("a sample")
        let data = try #require(try harness.pane.export(includeSamples: true))
        try await harness.pane.importProfile(data)
        #expect(harness.pane.profiles.count == BuiltInProfile.shipped.count + 1)
        #expect(harness.pane.samples.samples.count == 1)
    }
}

@Suite("Profiles pane copy")
struct ProfilesPaneCopyTests {
    @Test("every setting value and field name has copy in both languages", arguments: ["es", "en"])
    func dynamicKeys(_ language: String) throws {
        let path = try #require(Bundle.localized.path(forResource: "Localizable", ofType: "strings", inDirectory: nil,
                                                      forLocalization: language))
        let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
        let keys = ProfileSettings.Register.allCases.map { "profiles.register.\($0.rawValue)" }
            + ProfileSettings.Tone.allCases.map { "profiles.tone.\($0.rawValue)" }
            + ProfileSettings.Length.allCases.map { "profiles.length.\($0.rawValue)" }
            + ProfileSettings.Preserved.allCases.map { "profiles.preserve.\($0.rawValue)" }
            + ["name", "settings", "guidance", "examples", "model", "temperature"].map { "profiles.field.\($0)" }
        for key in keys { #expect(table[key] != nil, "\(key) in \(language)") }
    }
}
