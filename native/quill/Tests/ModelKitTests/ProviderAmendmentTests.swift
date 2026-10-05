import Foundation
import Testing

@testable import ModelKit

/// PROVIDERS §8 items 4–6: what each provider does differently.
@Suite("Provider-specific amendments")
struct ProviderAmendmentTests {
    private let store = InMemoryCredentialStore(["openai": "sk", "openrouter": "sk", "vercel-ai-gateway": "sk"])
    private let request = GenerationRequest(model: "m", instructions: "Fix spelling.", input: "q tal")

    @Test("every OpenRouter generation asks to be routed only to providers that do not collect data")
    func openRouterDataCollection() async throws {
        let transport = ScriptedTransport(.lines(sseStream("ok")))
        let provider = ChatCompletionsProvider.openRouter(credentials: store, transport: transport)
        _ = await collect(provider.stream(request))
        _ = await collect(provider.stream(GenerationRequest(model: "other/model", instructions: "i", input: "x",
                                                           options: GenerationOptions(temperature: 0.3))))
        #expect(transport.requests.count == 2)
        for sent in transport.requests {
            let routing = sent.jsonBody["provider"] as? [String: String]
            #expect(routing?["data_collection"] == "deny")
        }
    }

    @Test("other providers do not receive OpenRouter's routing object")
    func noRoutingElsewhere() async {
        for make in [ChatCompletionsProvider.openAI, ChatCompletionsProvider.vercelAIGateway] as [(any CredentialStore, any HTTPTransport, [ModelID]) -> ChatCompletionsProvider] {
            let transport = ScriptedTransport(.lines(sseStream("ok")))
            _ = await collect(make(store, transport, []).stream(request))
            #expect(transport.requests.first?.jsonBody["provider"] == nil)
        }
    }

    @Test("a loopback server carries the may-forward note; a remote one does not")
    func loopbackNote() {
        let local = ChatCompletionsProvider.custom(
            id: "local", displayName: "LM Studio", baseURL: URL(string: "http://127.0.0.1:1234/v1")!,
            requiresAPIKey: false, credentials: store)
        let remote = ChatCompletionsProvider.custom(
            id: "lan", displayName: "LAN", baseURL: URL(string: "https://models.example.local/v1")!,
            requiresAPIKey: true, credentials: store)
        #expect(local.descriptor.drawbacks.contains(.localServerMayForward))
        #expect(local.descriptor.advantages.contains(.staysOnDevice))
        #expect(!remote.descriptor.tradeoffs.contains(.localServerMayForward))
    }

    @Test("a single-use store hands a value out once, and only for its own key")
    func singleUse() async {
        let store = SingleUseStore<String, Int>()
        await store.put(1, for: "a")
        #expect(await store.take("b") == nil, "another request must not get this session")
        #expect(await store.take("a") == 1)
        #expect(await store.take("a") == nil, "a session never serves two generations")
        await store.put(2, for: "a")
        await store.put(3, for: "c")
        #expect(await store.take("a") == nil, "a newer prewarm replaces the older one")
        #expect(await store.take("c") == 3)
    }
}

#if canImport(FoundationModels)
import FoundationModels

@Suite("Apple on-device provider, amendments")
struct AppleOnDeviceAmendmentTests {
    @Test("the prewarm key is the request without its input")
    func prewarmKeyIgnoresInput() {
        let a = GenerationRequest(model: "system", instructions: "Fix.", input: "one",
                                  examples: [.init(input: "x", output: "X")])
        var b = a
        b.input = "two"
        var c = a
        c.instructions = "Rewrite."
        #expect(PrewarmKey(a) == PrewarmKey(b))
        #expect(PrewarmKey(a) != PrewarmKey(c))
    }

    @Test("no output cap reaches the framework, whatever the request asks")
    func noMaximumResponseTokens() {
        let request = GenerationRequest(model: "system", instructions: "i", input: "x",
                                        options: GenerationOptions(temperature: 0.2, maxOutputTokens: 50))
        let options = AppleOnDeviceProvider.options(request)
        #expect(options.maximumResponseTokens == nil)
        #expect(options.temperature == 0.2)
    }

    @Test("the context size comes from the framework")
    func contextFromFramework() {
        #expect(AppleOnDeviceProvider().descriptor.traits.maxContextTokens == AppleOnDeviceProvider.makeModel().contextSize)
    }

    @Test("generate answers through respond on this Mac", .enabled(if: AppleOnDeviceProviderTests.liveEnabled))
    func liveGenerate() async throws {
        let result = try await AppleOnDeviceProvider().generate(GenerationRequest(
            model: AppleOnDeviceProvider.modelID,
            instructions: "Fix the spelling of the user's text. Return only the corrected text.",
            input: "im runing late, see you at 5", options: GenerationOptions(temperature: 0)))
        #expect(!result.text.isEmpty)
        #expect(result.finishReason == .stop)
    }

    @Test("a prewarmed session serves the next matching request", .enabled(if: AppleOnDeviceProviderTests.liveEnabled))
    func livePrewarm() async throws {
        let provider = AppleOnDeviceProvider()
        let request = GenerationRequest(
            model: AppleOnDeviceProvider.modelID,
            instructions: "Fix the spelling of the user's text. Return only the corrected text.",
            input: "teh report is redy", options: GenerationOptions(temperature: 0))
        await provider.prewarm(for: request)
        let outcome = await collect(provider.stream(request))
        #expect(outcome.error == nil)
        #expect(!(outcome.result?.text.isEmpty ?? true))
        // The same request again must build a fresh session, not reuse the first.
        let again = await collect(provider.stream(request))
        #expect(again.error == nil)
    }

    @Test("token estimates use the framework's count on macOS 26.4 and later", .enabled(if: AppleOnDeviceProviderTests.liveEnabled))
    func liveTokenCount() async {
        let request = GenerationRequest(model: AppleOnDeviceProvider.modelID,
                                        instructions: "Fix the spelling of the user's text.",
                                        input: String(repeating: "the quick brown fox ", count: 20))
        let estimate = await AppleOnDeviceProvider().estimateTokens(request)
        #expect(estimate > 20 && estimate < 400, "\(estimate)")
    }
}
#endif
