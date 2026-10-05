import Foundation
import Testing

@testable import ModelKit

/// The behaviour every hosted provider must share, run against each preset.
///
/// A new Chat Completions preset is added to `Preset.all` and inherits the
/// whole suite. A provider with a different wire protocol writes its own
/// transport fixture but must pass the same scenarios: these ARE the contract.
@Suite("Provider contract")
struct ProviderContractTests {

    struct Preset: CustomTestStringConvertible, Sendable {
        let name: String
        let make: @Sendable (any CredentialStore, any HTTPTransport) -> ChatCompletionsProvider
        var testDescription: String { name }

        static let all: [Preset] = [
            Preset(name: "OpenAI") { .openAI(credentials: $0, transport: $1) },
            Preset(name: "OpenRouter") { .openRouter(credentials: $0, transport: $1) },
            Preset(name: "Vercel AI Gateway") { .vercelAIGateway(credentials: $0, transport: $1) },
        ]
    }

    private func provider(_ preset: Preset, _ transport: ScriptedTransport, key: String? = "sk-test") -> ChatCompletionsProvider {
        let probe = preset.make(InMemoryCredentialStore(), transport)
        let store = InMemoryCredentialStore(key.map { [probe.id: $0] } ?? [:])
        return preset.make(store, transport)
    }

    private func request(timeout: Duration = .seconds(5)) -> GenerationRequest {
        GenerationRequest(model: "some/model", instructions: "Fix spelling.", input: "q tal",
                          options: GenerationOptions(timeout: timeout))
    }

    @Test("streams deltas and finishes with exactly one result", arguments: Preset.all)
    func streamsAndCompletes(_ preset: Preset) async {
        let provider = provider(preset, ScriptedTransport(.lines(sseStream("How are you? 👋 Done ✓"))))
        let outcome = await collect(provider.stream(request()))

        #expect(outcome.error == nil)
        #expect(outcome.deltas.joined() == "How are you? 👋 Done ✓")
        #expect(outcome.result?.text == "How are you? 👋 Done ✓")
        #expect(outcome.result?.provider == provider.id)
        #expect(outcome.result?.model == "served-model", "the answering model, not the requested one")
        #expect(outcome.result?.usage == TokenUsage(inputTokens: 12, outputTokens: 5))
        #expect(outcome.result?.finishReason == .stop)
    }

    @Test("a missing key is reported before any network call", arguments: Preset.all)
    func missingKeyNeverHitsTheNetwork(_ preset: Preset) async {
        let transport = ScriptedTransport(.lines(sseStream("unused")))
        let provider = provider(preset, transport, key: nil)

        #expect(await provider.availability() == .unavailable(.missingCredential))
        let outcome = await collect(provider.stream(request()))
        #expect(outcome.error?.code == .unavailable(.missingCredential))
        #expect(transport.requests.isEmpty)
    }

    @Test("a rejected key maps to .authentication", arguments: Preset.all)
    func rejectedKey(_ preset: Preset) async {
        let body = #"{"error":{"message":"Invalid API key","type":"invalid_request_error"}}"#
        let provider = provider(preset, ScriptedTransport(.status(401, body: body)))
        let outcome = await collect(provider.stream(request()))

        #expect(outcome.error?.code == .authentication)
        #expect(outcome.error?.status == 401)
        #expect(outcome.error?.isRetriable == false)
    }

    @Test("cancelling a stream ends it quietly: no result, and no failure", arguments: Preset.all)
    func streamCancellation(_ preset: Preset) async {
        let provider = provider(preset, ScriptedTransport(.hang))
        let consumer = Task { await collect(provider.stream(request(timeout: .seconds(30)))) }
        try? await Task.sleep(for: .milliseconds(50))
        consumer.cancel()

        let outcome = await consumer.value
        #expect(outcome.result == nil)
        #expect(outcome.error == nil || outcome.error?.code == .cancelled, "cancellation must not look like a failure")
    }

    @Test("cancelling generate() throws .cancelled, never a foreign error type", arguments: Preset.all)
    func generateCancellation(_ preset: Preset) async {
        let provider = provider(preset, ScriptedTransport(.hang))
        let consumer = Task { () -> ProviderError? in
            do {
                _ = try await provider.generate(request(timeout: .seconds(30)))
                return nil
            } catch let error as ProviderError {
                return error
            } catch {
                return ProviderError(.server, "foreign error escaped: \(type(of: error))")
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        consumer.cancel()

        #expect(await consumer.value?.code == .cancelled)
    }

    @Test("a generation past its deadline fails with .timeout", arguments: Preset.all)
    func timeout(_ preset: Preset) async {
        let provider = provider(preset, ScriptedTransport(.hang))
        let outcome = await collect(provider.stream(request(timeout: .milliseconds(80))))

        #expect(outcome.error?.code == .timeout)
        #expect(outcome.error?.isRetriable == true)
    }

    @Test("the key travels as a bearer token and the text as the last user message", arguments: Preset.all)
    func requestShape(_ preset: Preset) async throws {
        let transport = ScriptedTransport(.lines(sseStream("ok")))
        _ = await collect(provider(preset, transport).stream(request()))

        let sent = try #require(transport.requests.first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(sent.url?.path().hasSuffix("/chat/completions") == true)
        let messages = try #require(sent.jsonBody["messages"] as? [[String: String]])
        #expect(messages.first?["role"] == "system")
        #expect(messages.last == ["role": "user", "content": "q tal"])
    }
}
