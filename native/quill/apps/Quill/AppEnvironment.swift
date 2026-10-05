import Foundation
import ModelKit
import QuillSupport
import RewriteKit

/// The app's long-lived objects, built once at launch — after `--self-check` has had
/// its chance to exit (ARCHITECTURE §8).
@MainActor
final class AppEnvironment {
    let dataDirectory: URL
    let settings: SettingsStore
    let profiles: ProfileStore
    let credentials: any CredentialStore
    let registry: ProviderRegistryHolder
    let modelCache: ModelListCache
    /// `readiness.json`, copied into the bundle by `make-app.sh`; empty when absent.
    let readiness: ReadinessIndex
    private let log = QuillLog(category: "environment")

    init(dataDirectory: URL = AppPaths.current,
         credentials: any CredentialStore = KeychainCredentialStore(
             service: AppPaths.keychainService(bundleIdentifier: Bundle.main.bundleIdentifier)),
         language: String = AppEnvironment.profileLanguage()) {
        self.dataDirectory = dataDirectory
        self.credentials = credentials
        let files = StoreFiles()
        files.sweepQuarantine(in: dataDirectory)
        settings = SettingsStore(dataDirectory: dataDirectory, files: files)
        profiles = ProfileStore(dataDirectory: dataDirectory, files: files)
        modelCache = ModelListCache(dataDirectory: dataDirectory, files: files)
        readiness = Bundle.main.url(forResource: "readiness", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }.flatMap { try? ReadinessIndex(data: $0) } ?? .empty

        let customServers = (try? settings.settings().customServers) ?? []
        let transport = HostLoggingTransport.live()
        let shipped = Self.shippedProviders(credentials: credentials, transport: transport)
        let makeCustom: ProviderRegistryHolder.CustomProviderFactory = {
            $0.makeProvider(credentials: credentials, transport: transport)
        }
        // A custom server colliding with a shipped id cannot be saved (its id carries
        // the `custom-` prefix); if a hand-edited file holds one anyway, start without
        // the custom servers rather than without a registry.
        registry = (try? ProviderRegistryHolder(shipped: shipped, customServers: customServers, makeCustom: makeCustom))
            ?? (try! ProviderRegistryHolder(shipped: shipped, customServers: [], makeCustom: makeCustom))
        registry.follow(settings) { [log] error in log.error("registry rebuild failed: \(error)") }

        do {
            try profiles.seedIfEmpty(language: language)
        } catch {
            log.error("could not seed the built-in profiles: \(error)")
        }
    }

    /// The shipped providers, in the order Settings lists them (PROVIDERS §4).
    static func shippedProviders(credentials: any CredentialStore,
                                 transport: any HTTPTransport = URLSessionTransport()) -> [any ModelProvider] {
        [
            AppleOnDeviceProvider(),
            ChatCompletionsProvider.openRouter(credentials: credentials, transport: transport,
                                               recommended: recommendedModels["openrouter"] ?? [], appTitle: QuillSupport.productName),
            ChatCompletionsProvider.vercelAIGateway(credentials: credentials, transport: transport,
                                                    recommended: recommendedModels["vercel-ai-gateway"] ?? []),
            ChatCompletionsProvider.openAI(credentials: credentials, transport: transport,
                                           recommended: recommendedModels["openai"] ?? []),
        ]
    }

    /// The models each preset recommends (README Q6, PLAN P1-T10): those the bench
    /// confirmed ready on the holdout for at least one built-in, measured through
    /// OpenRouter, and the same canonical identity on the other presets. Gemini has no
    /// OpenAI-direct equivalent. `RecommendedModelsTests` checks them against
    /// `readiness.json`.
    static let recommendedModels: [ProviderID: [ModelID]] = [
        "openrouter": ["google/gemini-3.8-flash", "openai/gpt-6-luna"],
        "vercel-ai-gateway": ["google/gemini-3.8-flash", "openai/gpt-6-luna"],
        "openai": ["gpt-6-luna"],
    ]

    /// Built-ins are named in the user's first preferred language Quill ships in.
    nonisolated static func profileLanguage(preferred: [String] = Locale.preferredLanguages) -> String {
        for identifier in preferred {
            let code = Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
            if ["es", "en"].contains(code) { return code }
        }
        return "en"
    }
}
