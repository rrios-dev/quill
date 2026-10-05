import Foundation
import ModelKit
import RewriteKit
import Testing

@testable import Quill

@MainActor
private final class PaneHarness {
    let folder: URL
    let settings: SettingsStore
    let profiles: ProfileStore
    let credentials = InMemoryCredentialStore()
    let hosted = FakeProvider(id: "openrouter", name: "OpenRouter", onDevice: false, context: nil)
    let holder: ProviderRegistryHolder
    let cache: ModelListCache
    let pane: ProvidersPaneModel

    init(readiness: ReadinessIndex = .empty) throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvidersPaneTests-\(UUID().uuidString)", isDirectory: true)
        settings = SettingsStore(dataDirectory: folder)
        profiles = ProfileStore(dataDirectory: folder)
        try profiles.seedIfEmpty(language: "es")
        cache = ModelListCache(dataDirectory: folder)
        let credentials = credentials
        holder = try ProviderRegistryHolder(
            shipped: [AppleOnDeviceProvider(), hosted, ChatCompletionsProvider.openAI(credentials: credentials)],
            customServers: [], makeCustom: { $0.makeProvider(credentials: credentials) })
        holder.follow(settings)
        pane = ProvidersPaneModel(settings: settings, profiles: profiles, registry: holder, credentials: credentials,
                                  cache: cache, readiness: readiness)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func row(_ id: ProviderID) -> ProvidersPaneModel.Row? { pane.rows.first { $0.id == id } }
}

@Suite("Providers & models pane", .serialized)
@MainActor
struct ProvidersPaneTests {
    @Test("a missing key shows needs a key, with the action to add one")
    func missingKey() async throws {
        let harness = try PaneHarness()
        await harness.pane.refresh()
        let openAI = try #require(harness.row("openai"))
        #expect(openAI.needsKey && !openAI.hasKey)
        let status = try #require(harness.pane.status(of: openAI))
        #expect(status.key == "picker.failure.missingKey")
        #expect(status.action == .openProviderSettings)
        #expect(openAI.drawbacks.contains(.requiresAPIKey))
    }

    @Test("saving a key clears the status; removing it deletes the Keychain item")
    func keys() async throws {
        let harness = try PaneHarness()
        try await harness.pane.setKey("  test-value  ", for: "openai")
        #expect(try harness.credentials.secret(for: "openai") == "test-value")
        #expect(harness.row("openai")?.hasKey == true)
        #expect(harness.pane.status(of: try #require(harness.row("openai"))) == nil)

        try await harness.pane.removeKey(for: "openai")
        #expect(try harness.credentials.secret(for: "openai") == nil)
        #expect(harness.pane.status(of: try #require(harness.row("openai")))?.key == "picker.failure.missingKey")

        try await harness.pane.setKey("   ", for: "openai")
        #expect(try harness.credentials.secret(for: "openai") == nil, "an empty key is not saved")
    }

    @Test("a loopback server shows its forwarding note and is on-device")
    func loopbackNote() async throws {
        let harness = try PaneHarness()
        let id = try await harness.pane.addCustomServer(name: "Ollama", address: "http://localhost:11434/v1",
                                                        requiresKey: false, key: "")
        let row = try #require(harness.row(id))
        #expect(row.isCustom && !row.isRemote)
        #expect(row.drawbacks.contains(.localServerMayForward))
        #expect(row.advantages.contains(.staysOnDevice))
    }

    @Test("the address rule: https, or http only to this Mac or a .local name", arguments: [
        ("https://gateway.example.com/v1", true), ("http://localhost:1234/v1", true), ("http://127.0.0.1:8080", true),
        ("http://nas.local:11434/v1", true), ("http://192.168.1.20:11434/v1", false), ("http://10.0.0.5", false),
        ("http://[fd00::1]:8080", false), ("http://gateway.example.com", false), ("ftp://nas.local", false), ("not a url", false),
    ])
    func addressRule(_ address: String, _ accepted: Bool) async throws {
        let harness = try PaneHarness()
        do {
            try await harness.pane.addCustomServer(name: "Server", address: address, requiresKey: false, key: "")
            #expect(accepted, "\(address) was accepted")
        } catch {
            #expect(!accepted, "\(address) was refused: \(error)")
        }
    }

    @Test("plain http to an address is refused with an explanation naming it")
    func addressExplanation() async throws {
        let harness = try PaneHarness()
        do {
            try await harness.pane.addCustomServer(name: "LAN", address: "http://192.168.1.20/v1", requiresKey: false, key: "")
            Issue.record("accepted")
        } catch .address(let problem) {
            #expect(problem == .plainHTTPToAddress("192.168.1.20"))
            #expect(ProvidersPaneModel.explanation(problem).text.contains("192.168.1.20"))
        } catch {
            Issue.record("\(error)")
        }
        #expect(try harness.settings.settings().customServers.isEmpty)
    }

    @Test("a server that needs a key is not added without one, and its key goes to the Keychain")
    func serverKey() async throws {
        let harness = try PaneHarness()
        await #expect(throws: ProvidersPaneModel.AddServerError.key) {
            try await harness.pane.addCustomServer(name: "Gateway", address: "https://gw.example.com/v1", requiresKey: true, key: "")
        }
        let id = try await harness.pane.addCustomServer(name: "Gateway", address: "https://gw.example.com/v1",
                                                        requiresKey: true, key: "test-value")
        #expect(try harness.credentials.secret(for: id) == "test-value")
        #expect(harness.row(id)?.isRemote == true)
    }

    @Test("removing a server removes its key, its cached list and a global model on it")
    func removeServer() async throws {
        let harness = try PaneHarness()
        let id = try await harness.pane.addCustomServer(name: "Gateway", address: "https://gw.example.com/v1",
                                                        requiresKey: true, key: "test-value")
        try harness.settings.update { $0.globalModel = ModelSelection(provider: id, model: "m") }
        await harness.pane.removeCustomServer(id)
        #expect(try harness.credentials.secret(for: id) == nil)
        #expect(try harness.settings.settings().customServers.isEmpty)
        #expect(try harness.settings.settings().globalModel == nil)
        #expect(harness.row(id) == nil)
    }

    @Test("the remote notice appears once per provider")
    func noticeOnce() async throws {
        let harness = try PaneHarness()
        await harness.pane.refresh()
        let first = ModelSelection(provider: "openrouter", model: "vendor/one")
        harness.pane.choose(first)
        #expect(harness.pane.notice?.recipients == [.named("OpenRouter"), .routedInferenceProvider])
        #expect(try harness.settings.settings().globalModel == nil, "nothing changes before acceptance")
        harness.pane.declineNotice()
        #expect(try harness.settings.settings().globalModel == nil)

        harness.pane.choose(first)
        harness.pane.acceptNotice()
        #expect(try harness.settings.settings().globalModel == first)
        #expect(try harness.settings.settings().notifiedProviders.contains("openrouter"))

        let second = ModelSelection(provider: "openrouter", model: "vendor/two")
        harness.pane.choose(second)
        #expect(harness.pane.notice == nil)
        #expect(try harness.settings.settings().globalModel == second)

        harness.pane.choose(ModelSelection(provider: "apple.on-device", model: "system"))
        #expect(harness.pane.notice == nil, "on-device needs no notice")
    }

    @Test("model lists are cached: a second load does not fetch, a refresh does")
    func modelCache() async throws {
        let harness = try PaneHarness()
        harness.hosted.modelsResult = .success([ModelDescriptor(
            id: "vendor/one", contextTokens: 128_000, pricing: ModelPricing(inputPerMillion: 1, outputPerMillion: 2))])
        await harness.pane.refresh()
        await harness.pane.loadModels(for: "openrouter")
        await harness.pane.loadModels(for: "openrouter")
        #expect(harness.hosted.modelFetches == 1)
        #expect(harness.row("openrouter")?.models.first?.pricing?.outputPerMillion == 2)
        await harness.pane.loadModels(for: "openrouter", force: true)
        #expect(harness.hosted.modelFetches == 2)
        // A new pane reads the stored list without asking the provider.
        let other = ProvidersPaneModel(settings: harness.settings, profiles: harness.profiles, registry: harness.holder,
                                       credentials: harness.credentials, cache: harness.cache, readiness: .empty)
        await other.refresh()
        #expect(other.rows.first { $0.id == "openrouter" }?.models.count == 1)
        #expect(harness.hosted.modelFetches == 2)
    }

    @Test("test connection reports the models, or the failure with its copy")
    func testConnection() async throws {
        let harness = try PaneHarness()
        await harness.pane.refresh()
        harness.hosted.modelsResult = .success([ModelDescriptor(id: "a"), ModelDescriptor(id: "b")])
        await harness.pane.testConnection("openrouter")
        #expect(harness.row("openrouter")?.connection == .ok(models: 2))
        harness.hosted.modelsResult = .failure(ProviderError(.insecureConnection, "ATS"))
        await harness.pane.testConnection("openrouter")
        #expect(harness.row("openrouter")?.connection == .failed(.insecureConnection))
        #expect(Presentation.providerError(.insecureConnection).text.contains(".local"))
    }

    @Test("models show the last used profile's readiness label")
    func readiness() async throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../tools/QuillBench/data/readiness.json").standardizedFileURL
        let harness = try PaneHarness(readiness: try ReadinessIndex(data: Data(contentsOf: file)))
        let spelling = try #require(try harness.profiles.all().profiles.first { $0.builtIn == .spelling })
        try harness.settings.update { $0.lastUsedProfile = spelling.id }
        let model = ModelDescriptor(id: "system", contextTokens: 4_096)
        let label = harness.pane.readiness(of: model, provider: "apple.on-device")
        if [26, 27].contains(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
            #expect(label == .notRecommended)
        } else {
            #expect(label == .notEvaluated, "another macOS major is another model")
        }
    }

    @Test("the browser filters by every word, recommended first; the pane lists only a few")
    func browserAndFeatured() async throws {
        let harness = try PaneHarness()
        var models = (1...40).map { ModelDescriptor(id: ModelID(rawValue: "vendor/model-\($0)"), displayName: "Model \($0)") }
        models.append(ModelDescriptor(id: "google/gemini-3.8-flash", displayName: "Gemini 3.8 Flash", isRecommended: true))
        harness.hosted.modelsResult = .success(models)
        await harness.pane.refresh()
        await harness.pane.loadModels(for: "openrouter", force: true)
        let all = try #require(harness.pane.browse("", provider: "openrouter").first)
        #expect(all.models.count == 41)
        #expect(all.models.first?.id == "google/gemini-3.8-flash", "recommended first")
        #expect(harness.pane.browse("gemini flash").flatMap(\.models).map(\.id) == ["google/gemini-3.8-flash"])
        #expect(harness.pane.browse("no such model").isEmpty)
        let row = try #require(harness.row("openrouter"))
        #expect(harness.pane.featuredModels(of: row).map(\.id) == ["google/gemini-3.8-flash"],
                "a catalogue of 41 shows its recommended model inline, not 41 rows")
        #expect(harness.pane.labels.count >= 41, "every listed model has its label computed once")
    }

    @Test("a cached list is decoded once and read again when its file changes")
    func cacheMemo() async throws {
        let harness = try PaneHarness()
        harness.hosted.modelsResult = .success([ModelDescriptor(id: "a/one", displayName: "One")])
        _ = try await harness.cache.models(of: harness.hosted, force: true)
        #expect(harness.cache.cached("openrouter")?.models.map(\.id) == ["a/one"])
        harness.hosted.modelsResult = .success([ModelDescriptor(id: "a/two", displayName: "Two")])
        _ = try await harness.cache.models(of: harness.hosted, force: true)
        #expect(harness.cache.cached("openrouter")?.models.map(\.id) == ["a/two"], "a write is never hidden by the memo")
        harness.cache.remove("openrouter")
        #expect(harness.cache.cached("openrouter") == nil)
    }
}
