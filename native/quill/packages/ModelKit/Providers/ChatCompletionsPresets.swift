import Foundation

/// The hosted providers we ship, as presets of the Chat Completions adapter.
///
/// Model ids are not hardcoded here: catalogues change monthly, and which
/// models to recommend is a product decision the app passes in through
/// `recommended`. The contract only knows how to list what the provider offers.
extension ChatCompletionsProvider {
    public static func openAI(credentials: any CredentialStore, transport: any HTTPTransport = URLSessionTransport(),
                              recommended: [ModelID] = []) -> ChatCompletionsProvider {
        ChatCompletionsProvider(
            descriptor: ProviderDescriptor(
                id: "openai",
                displayName: "OpenAI",
                traits: ProviderTraits(execution: .remote(recipients: [.named("OpenAI")]), cost: .payPerUse, credential: .apiKey),
                notes: [.singleRecipient, .strongModels, .singleVendorCatalog]),
            endpoint: Endpoint(baseURL: URL(string: "https://api.openai.com/v1")!, maxTokensField: "max_completion_tokens",
                               defaultVendor: "openai"),
            credentials: credentials, transport: transport, recommended: recommended)
    }

    /// `appURL` and `appTitle` feed OpenRouter's optional attribution headers.
    public static func openRouter(credentials: any CredentialStore, transport: any HTTPTransport = URLSessionTransport(),
                                  recommended: [ModelID] = [], appURL: String? = nil, appTitle: String? = nil) -> ChatCompletionsProvider {
        var headers: [String: String] = [:]
        if let appURL { headers["HTTP-Referer"] = appURL }
        if let appTitle { headers["X-OpenRouter-Title"] = appTitle }
        return ChatCompletionsProvider(
            descriptor: ProviderDescriptor(
                id: "openrouter",
                displayName: "OpenRouter",
                traits: ProviderTraits(execution: .remote(recipients: [.named("OpenRouter"), .routedInferenceProvider]), cost: .payPerUse, credential: .apiKey),
                notes: [.manyModels, .strongModels, .dataPolicyVariesByModel]),
            endpoint: Endpoint(baseURL: URL(string: "https://openrouter.ai/api/v1")!, headers: headers,
                               routingPreferences: ["data_collection": "deny"]),
            credentials: credentials, transport: transport, recommended: recommended)
    }

    public static func vercelAIGateway(credentials: any CredentialStore, transport: any HTTPTransport = URLSessionTransport(),
                                       recommended: [ModelID] = []) -> ChatCompletionsProvider {
        ChatCompletionsProvider(
            descriptor: ProviderDescriptor(
                id: "vercel-ai-gateway",
                displayName: "Vercel AI Gateway",
                traits: ProviderTraits(execution: .remote(recipients: [.named("Vercel"), .modelServingProvider]), cost: .payPerUse, credential: .apiKey),
                notes: [.manyModels, .strongModels, .dataPolicyVariesByModel]),
            endpoint: Endpoint(baseURL: URL(string: "https://ai-gateway.vercel.sh/v1")!),
            credentials: credentials, transport: transport, recommended: recommended)
    }

    /// Any other server that speaks the protocol: Ollama, LM Studio, a company
    /// gateway. A loopback URL is classified as on-device and free, because it is.
    public static func custom(id: ProviderID, displayName: String, baseURL: URL, requiresAPIKey: Bool,
                              credentials: any CredentialStore, transport: any HTTPTransport = URLSessionTransport()) -> ChatCompletionsProvider {
        let isLoopback = ["localhost", "127.0.0.1", "::1"].contains(baseURL.host() ?? "")
        let traits = ProviderTraits(
            execution: isLoopback ? .onDevice : .remote(recipients: [.host(baseURL.host() ?? displayName)]),
            cost: isLoopback ? .free : .payPerUse,
            credential: requiresAPIKey ? .apiKey : .none)
        // A local proxy (LiteLLM, for one) can forward to the cloud itself, so "on this
        // Mac" is only as true as the server makes it (PROVIDERS §8 item 6).
        return ChatCompletionsProvider(
            descriptor: ProviderDescriptor(id: id, displayName: displayName, traits: traits,
                                           notes: isLoopback ? [.localServerMayForward] : []),
            endpoint: Endpoint(baseURL: baseURL),
            credentials: credentials, transport: transport)
    }
}
