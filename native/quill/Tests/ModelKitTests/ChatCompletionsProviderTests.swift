import Foundation
import Testing

@testable import ModelKit

/// Dialect details of the Chat Completions adapter that the shared contract
/// suite does not cover: encoding, model listing and error-body mapping.
@Suite("Chat Completions adapter")
struct ChatCompletionsProviderTests {

    private let store = InMemoryCredentialStore(["openai": "sk", "openrouter": "sk", "vercel-ai-gateway": "sk"])

    @Test("App Transport Security's -1022 is an insecure connection, not a network failure")
    func atsRefusal() {
        let error = ProviderError.normalize(URLError(.appTransportSecurityRequiresSecureConnection), provider: "custom-lan")
        #expect(error.code == .insecureConnection)
        #expect(!error.isRetriable)
        #expect(ProviderError.normalize(URLError(.notConnectedToInternet), provider: "custom-lan").code == .network)
    }

    @Test("examples become alternating user/assistant turns before the input")
    func examplesAsTurns() throws {
        let provider = ChatCompletionsProvider.openRouter(credentials: store)
        let request = GenerationRequest(
            model: "m", instructions: "Rewrite.", input: "target",
            examples: [.init(input: "a", output: "A"), .init(input: "b", output: "B")])
        let body = try JSONSerialization.jsonObject(with: provider.encodeBody(request)) as? [String: Any]
        let roles = (body?["messages"] as? [[String: String]])?.map { $0["role"]! }

        #expect(roles == ["system", "user", "assistant", "user", "assistant", "user"])
    }

    @Test("OpenAI receives max_completion_tokens; the others max_tokens")
    func maxTokensDialect() throws {
        let request = GenerationRequest(model: "m", instructions: "i", input: "x",
                                        options: GenerationOptions(temperature: 0.2, maxOutputTokens: 300))
        let openAI = try JSONSerialization.jsonObject(with: ChatCompletionsProvider.openAI(credentials: store).encodeBody(request)) as? [String: Any]
        let gateway = try JSONSerialization.jsonObject(with: ChatCompletionsProvider.vercelAIGateway(credentials: store).encodeBody(request)) as? [String: Any]

        #expect(openAI?["max_completion_tokens"] as? Int == 300)
        #expect(openAI?["max_tokens"] == nil)
        #expect(gateway?["max_tokens"] as? Int == 300)
        #expect(gateway?["temperature"] as? Double == 0.2)
    }

    @Test("unset options are omitted, so each model keeps its own default")
    func unsetOptionsOmitted() throws {
        let body = try JSONSerialization.jsonObject(
            with: ChatCompletionsProvider.openAI(credentials: store).encodeBody(GenerationRequest(model: "m", instructions: "i", input: "x"))) as? [String: Any]

        #expect(body?["temperature"] == nil, "reasoning models reject a non-default temperature")
        #expect(body?["max_completion_tokens"] == nil)
    }

    @Test("OpenRouter attribution headers are sent only when configured")
    func openRouterHeaders() async throws {
        let transport = ScriptedTransport(.lines(sseStream("ok")))
        let provider = ChatCompletionsProvider.openRouter(credentials: store, transport: transport,
                                                          appURL: "https://example.app", appTitle: "Example App")
        _ = await collect(provider.stream(GenerationRequest(model: "m", instructions: "i", input: "x")))

        let sent = try #require(transport.requests.first)
        #expect(sent.value(forHTTPHeaderField: "HTTP-Referer") == "https://example.app")
        #expect(sent.value(forHTTPHeaderField: "X-OpenRouter-Title") == "Example App")
    }

    @Test("the model list reads both context field spellings and puts recommended first")
    func modelList() async throws {
        let json = #"""
        {"data":[
          {"id":"zeta/large","name":"Zeta Large","context_length":200000},
          {"id":"alpha/small","context_window":32000},
          {"id":"mid/model"}
        ]}
        """#
        let provider = ChatCompletionsProvider.openRouter(credentials: store, transport: ScriptedTransport(.lines([json])),
                                                          recommended: ["zeta/large"])
        let models = try await provider.models()

        #expect(models.map(\.id) == ["zeta/large", "alpha/small", "mid/model"])
        #expect(models[0].isRecommended && models[0].displayName == "Zeta Large" && models[0].contextTokens == 200_000)
        #expect(models[1].contextTokens == 32_000)
    }

    @Test("HTTP failures map onto contract codes", arguments: [
        (429, #"{"error":{"message":"slow down"}}"#, ["Retry-After": "7"], ProviderError.Code.rateLimited(retryAfter: .seconds(7))),
        (400, #"{"error":{"message":"too long","code":"context_length_exceeded"}}"#, [:], .contextExceeded),
        (400, #"{"error":{"message":"bad model","code":"model_not_found"}}"#, [:], .invalidRequest),
        (402, #"{"error":{"message":"no credits","code":402}}"#, [:], .rateLimited(retryAfter: nil)),
        (503, "upstream down", [:], .server),
    ])
    func httpErrorMapping(status: Int, body: String, headers: [String: String], expected: ProviderError.Code) async {
        let provider = ChatCompletionsProvider.openRouter(credentials: store, transport: ScriptedTransport(.status(status, body: body, headers: headers)))
        let outcome = await collect(provider.stream(GenerationRequest(model: "m", instructions: "i", input: "x")))

        #expect(outcome.error?.code == expected)
        #expect(outcome.error?.status == status)
    }

    @Test("an error delivered inside a 200 stream is not mistaken for an empty answer")
    func errorInsideStream() async {
        let lines = [
            #"data: {"choices":[{"delta":{"content":"Hal"}}]}"#,
            #"data: {"error":{"message":"Provider overloaded","code":503}}"#,
        ]
        let provider = ChatCompletionsProvider.openRouter(credentials: store, transport: ScriptedTransport(.lines(lines)))
        let outcome = await collect(provider.stream(GenerationRequest(model: "m", instructions: "i", input: "x")))

        #expect(outcome.result == nil)
        #expect(outcome.error?.code == .server)
        #expect(outcome.error?.message == "Provider overloaded")
    }

    @Test("an unreadable chunk fails as .malformedResponse")
    func malformedChunk() async {
        let provider = ChatCompletionsProvider.openAI(credentials: store, transport: ScriptedTransport(.lines(["data: {not json"])))
        let outcome = await collect(provider.stream(GenerationRequest(model: "m", instructions: "i", input: "x")))

        #expect(outcome.error?.code == .malformedResponse)
    }

    @Test("a loopback custom server is classified as on-device, free and keyless")
    func loopbackCustomServer() async {
        let provider = ChatCompletionsProvider.custom(id: "ollama", displayName: "Ollama",
                                                      baseURL: URL(string: "http://localhost:11434/v1")!,
                                                      requiresAPIKey: false, credentials: InMemoryCredentialStore())

        #expect(provider.descriptor.traits.execution == .onDevice)
        #expect(provider.descriptor.advantages.contains(.staysOnDevice))
        #expect(await provider.availability() == .available)
    }
}
