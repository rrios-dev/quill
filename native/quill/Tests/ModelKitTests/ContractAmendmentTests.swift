import Foundation
import Testing

@testable import ModelKit

/// PROVIDERS §8 items 1–3 and 7–8: the contract amendments RewriteKit depends on.
@Suite("Contract amendments")
struct ContractAmendmentTests {
    private let store = InMemoryCredentialStore(["openai": "sk", "openrouter": "sk", "vercel-ai-gateway": "sk"])
    private let request = GenerationRequest(model: "m", instructions: "Fix spelling.", input: "q tal")

    // MARK: Finish reason

    @Test("a finish_reason of length surfaces as .length, so a cut-off answer is never mistaken for a whole one")
    func finishReasonLength() async {
        let provider = ChatCompletionsProvider.openRouter(
            credentials: store, transport: ScriptedTransport(.lines(sseStream("Half of the", finishReason: "length"))))
        let outcome = await collect(provider.stream(request))
        #expect(outcome.result?.finishReason == .length)
        #expect(outcome.result?.text == "Half of the")
    }

    @Test("finish reasons map onto the contract", arguments: [
        ("stop", FinishReason.stop), ("length", .length), ("content_filter", .contentFilter), ("tool_calls", .unknown),
    ])
    func finishReasonMapping(raw: String, expected: FinishReason) async {
        let provider = ChatCompletionsProvider.openAI(
            credentials: store, transport: ScriptedTransport(.lines(sseStream("Done", finishReason: raw))))
        #expect(await collect(provider.stream(request)).result?.finishReason == expected)
    }

    @Test("a stream that never says why it stopped reports .unknown")
    func finishReasonMissing() async {
        let provider = ChatCompletionsProvider.openAI(
            credentials: store, transport: ScriptedTransport(.lines(sseStream("Done", finishReason: nil))))
        #expect(await collect(provider.stream(request)).result?.finishReason == .unknown)
    }

    // MARK: Prices and vendor

    @Test("OpenRouter's model list yields prices per million tokens and the vendor from the id")
    func openRouterPricing() async throws {
        let json = #"""
        {"data":[
          {"id":"anthropic/claude-example","name":"Claude Example","context_length":200000,
           "pricing":{"prompt":"0.000003","completion":"0.000015","request":"0"}},
          {"id":"mistralai/small","pricing":{"prompt":"0","completion":"0"}},
          {"id":"odd/unpriced","pricing":{"prompt":"-1","completion":"-1"}},
          {"id":"bare-model"}
        ]}
        """#
        let models = try await ChatCompletionsProvider.openRouter(
            credentials: store, transport: ScriptedTransport(.lines([json]))).models()
        let claude = try #require(models.first { $0.id == "anthropic/claude-example" })
        #expect(claude.vendor == "anthropic")
        #expect(abs((claude.pricing?.inputPerMillion ?? 0) - 3) < 1e-9)
        #expect(abs((claude.pricing?.outputPerMillion ?? 0) - 15) < 1e-9)
        #expect(models.first { $0.id == "mistralai/small" }?.pricing == ModelPricing(inputPerMillion: 0, outputPerMillion: 0))
        #expect(models.first { $0.id == "odd/unpriced" }?.pricing == nil, "a negative price means unknown, not a refund")
        let bare = try #require(models.first { $0.id == "bare-model" })
        #expect(bare.vendor == nil && bare.pricing == nil)
    }

    @Test("the gateway's input/output price names are read too")
    func gatewayPricing() async throws {
        let json = #"{"data":[{"id":"openai/gpt-example","pricing":{"input":"0.0000025","output":"0.00001"}}]}"#
        let models = try await ChatCompletionsProvider.vercelAIGateway(
            credentials: store, transport: ScriptedTransport(.lines([json]))).models()
        #expect(models.first?.vendor == "openai")
        #expect(abs((models.first?.pricing?.inputPerMillion ?? 0) - 2.5) < 1e-9)
    }

    @Test("OpenAI's own ids, which carry no prefix, have OpenAI as vendor and no published price")
    func openAIVendor() async throws {
        let json = #"{"data":[{"id":"gpt-example"}]}"#
        let models = try await ChatCompletionsProvider.openAI(
            credentials: store, transport: ScriptedTransport(.lines([json]))).models()
        #expect(models.first?.vendor == "openai")
        #expect(models.first?.pricing == nil)
    }

    @Test("a price turns usage into dollars")
    func costOfUsage() {
        let price = ModelPricing(inputPerMillion: 3, outputPerMillion: 15)
        #expect(abs(price.cost(of: TokenUsage(inputTokens: 1_000, outputTokens: 2_000)) - 0.033) < 1e-12)
    }

    // MARK: Defaults of the new requirements

    /// A provider that implements only what the contract requires.
    private struct MinimalProvider: ModelProvider {
        let descriptor = ProviderDescriptor(
            id: "minimal", displayName: "Minimal",
            traits: ProviderTraits(execution: .onDevice, cost: .free, credential: .none))
        let calls = Counter()

        func availability() async -> ProviderAvailability { .available }
        func models() async throws -> [ModelDescriptor] { [] }
        func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error> {
            calls.increment()
            return AsyncThrowingStream { continuation in
                continuation.yield(.delta("ok"))
                continuation.yield(.completed(GenerationResult(
                    text: "ok", provider: "minimal", model: request.model, latency: .zero, finishReason: .stop)))
                continuation.finish()
            }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @Test("prewarm defaults to doing nothing — no generation is started")
    func prewarmDefault() async {
        let provider = MinimalProvider()
        await provider.prewarm(for: request)
        #expect(provider.calls.count == 0)
    }

    @Test("estimateTokens defaults to characters ÷ 3.5, rounded up, over instructions, examples and input")
    func estimateDefault() async {
        let provider = MinimalProvider()
        let withExamples = GenerationRequest(
            model: "m", instructions: String(repeating: "a", count: 10), input: String(repeating: "b", count: 11),
            examples: [.init(input: "ccc", output: "dddd")])
        // 10 + 11 + 3 + 4 = 28 characters → 8 tokens.
        #expect(await provider.estimateTokens(withExamples) == 8)
        #expect(await provider.estimateTokens(GenerationRequest(model: "m", instructions: "", input: "")) == 0)
    }

    @Test("generate defaults to collecting the stream, and is reachable through the existential")
    func generateDefault() async throws {
        let provider: any ModelProvider = MinimalProvider()
        let result = try await provider.generate(request)
        #expect(result.text == "ok" && result.finishReason == .stop)
    }

    // MARK: Credential reset

    @Test("removeAll deletes every key of the store")
    func removeAll() throws {
        let keys = InMemoryCredentialStore(["openai": "sk-1", "custom.lan": "sk-2"])
        try keys.removeAll()
        #expect(try keys.secret(for: "openai") == nil)
        #expect(try keys.secret(for: "custom.lan") == nil)
    }
}
