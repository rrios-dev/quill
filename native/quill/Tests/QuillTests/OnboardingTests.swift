import AppCore
import Foundation
import ModelKit
import RewriteKit
import SelectionKit
import Testing

@testable import Quill

@Suite("Onboarding", .serialized)
@MainActor
struct OnboardingTests {
    /// A readiness file labelling every built-in `label` on this Mac's on-device model.
    static func fixture(label: String) throws -> ReadinessIndex {
        let composer = try PromptComposer()
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let entries = try BuiltInProfiles.all(language: "es").map { profile -> [String: Any] in
            ["promptHash": composer.promptHash(profile: profile, strategy: .compact), "model": "apple/on-device@\(major)",
             "evaluationVersion": RewriteKitVersion.evaluation, "verdict": "-", "label": label]
        }
        return try ReadinessIndex(data: JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "entries": entries]))
    }

    private func model(readiness: ReadinessIndex = .empty, onDevice: ProviderAvailability = .available,
                       relocation: AppRelocation.Decision = .alreadyInPlace, access: PasteboardAccess = .alwaysAllow,
                       trusted: Bool = false) throws -> (OnboardingModel, SettingsStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OnboardingTests-\(UUID().uuidString)")
        let settings = SettingsStore(dataDirectory: folder)
        let profiles = ProfileStore(dataDirectory: folder)
        try profiles.seedIfEmpty(language: "es")
        let local = FakeProvider(id: AppleOnDeviceProvider.providerID, name: "Apple Intelligence", onDevice: true, context: 4_096)
        local.availabilityValue = onDevice
        let hosted = FakeProvider(id: "openrouter", name: "OpenRouter", onDevice: false, context: nil)
        let credentials = InMemoryCredentialStore()
        let holder = try ProviderRegistryHolder(shipped: [local, hosted], customServers: [], makeCustom: { _ in fatalError() })
        let providers = ProvidersPaneModel(settings: settings, profiles: profiles, registry: holder, credentials: credentials,
                                           cache: ModelListCache(dataDirectory: folder), readiness: readiness)
        let model = OnboardingModel(settings: settings, profiles: profiles, registry: holder, readiness: readiness,
                                    providers: providers, relocation: relocation, isTrusted: { trusted }, readAccess: { access })
        return (model, settings, folder)
    }

    @Test("the on-device model is preselected only when every built-in works well on it")
    func providerDefault() async throws {
        let (worksWell, _, a) = try model(readiness: try Self.fixture(label: "works well"))
        defer { try? FileManager.default.removeItem(at: a) }
        await worksWell.evaluateProviders()
        #expect(worksWell.providerDefault == .onDevice)
        #expect(worksWell.onDeviceLabel == .worksWell)

        let (review, _, b) = try model(readiness: try Self.fixture(label: "may need review"))
        defer { try? FileManager.default.removeItem(at: b) }
        await review.evaluateProviders()
        #expect(review.providerDefault == .hosted, "may need review does not count (README Q5)")

        let (off, _, c) = try model(readiness: try Self.fixture(label: "works well"), onDevice: .unavailable(.appleIntelligenceDisabled))
        defer { try? FileManager.default.removeItem(at: c) }
        await off.evaluateProviders()
        #expect(off.providerDefault == .hosted)
        #expect(off.offersAppleIntelligenceSettings)
    }

    @Test("the committed readiness file recommends a hosted model")
    func committedFile() async throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../tools/QuillBench/data/readiness.json").standardizedFileURL
        let (model, _, folder) = try model(readiness: try ReadinessIndex(data: Data(contentsOf: file)))
        defer { try? FileManager.default.removeItem(at: folder) }
        await model.evaluateProviders()
        #expect(model.providerDefault == .hosted)
    }

    @Test("relocation shows only when there is something to offer; the clipboard step only where enforced")
    func steps() {
        let offer = AppRelocation.Decision.offerMove(from: URL(fileURLWithPath: "/tmp/Quill.app"),
                                                     to: URL(fileURLWithPath: "/Applications/Quill.app"))
        #expect(OnboardingModel.steps(relocation: .alreadyInPlace, clipboardAccess: .alwaysAllow)
                == [.welcome, .accessibility, .provider, .shortcut, .practice])
        #expect(OnboardingModel.steps(relocation: offer, clipboardAccess: .default)
                == [.welcome, .relocate, .accessibility, .clipboard, .provider, .shortcut, .practice])
    }

    @Test("walking forward and back stays inside the steps; finishing records it")
    func walk() throws {
        let (model, settings, folder) = try model()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.back()
        #expect(model.current == .welcome)
        for _ in 0..<10 { model.next() }
        #expect(model.current == .practice && model.isLast)
        model.back()
        #expect(model.current == .shortcut)
        model.finish()
        #expect(try settings.settings().onboardingCompleted)
    }

    @Test("a grant that arrives during onboarding asks for a restart")
    func grant() throws {
        var trusted = false
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OnboardingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = SettingsStore(dataDirectory: folder)
        let holder = try ProviderRegistryHolder(shipped: [], customServers: [], makeCustom: { _ in fatalError() })
        let model = OnboardingModel(
            settings: settings, profiles: ProfileStore(dataDirectory: folder), registry: holder, readiness: .empty,
            providers: ProvidersPaneModel(settings: settings, profiles: ProfileStore(dataDirectory: folder), registry: holder,
                                          credentials: InMemoryCredentialStore(), cache: ModelListCache(dataDirectory: folder),
                                          readiness: .empty),
            relocation: .alreadyInPlace, isTrusted: { trusted }, readAccess: { .alwaysAllow })
        #expect(model.permission == .notTrusted)
        trusted = true
        model.refreshPermission()
        #expect(model.permission == .grantedWhileRunning)
    }

    @Test("choosing Apple Intelligence makes it the global model")
    func chooseOnDevice() throws {
        let (model, settings, folder) = try model()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.chooseOnDevice()
        #expect(try settings.settings().globalModel == ModelSelection(provider: AppleOnDeviceProvider.providerID, model: "system"))
    }
}
