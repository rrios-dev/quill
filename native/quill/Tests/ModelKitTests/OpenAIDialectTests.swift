import Foundation
import Testing

@testable import ModelKit

/// OpenAI refuses what OpenRouter quietly drops. A colleague's meeting syntheses failed
/// through OpenAI with the same model that works through OpenRouter (2026-10-30); these
/// replay OpenAI's refusals, with its own wording, against the adapter.
@Suite("OpenAI dialect")
struct OpenAIDialectTests {
    private let store = InMemoryCredentialStore(["openai": "sk"])

    static let temperatureRefusal = #"{"error":{"message":"Unsupported value: 'temperature' does not support 0.2 with this model. Only the default (1) value is supported.","type":"invalid_request_error","param":"temperature","code":"unsupported_value"}}"#
    static let streamRefusal = #"{"error":{"message":"Your organization must be verified to stream this model. Please go to: https://platform.openai.com/settings/organization/general and click on Verify Organization.","type":"invalid_request_error","param":"stream","code":"unsupported_value"}}"#

    static func body(_ request: URLRequest) -> [String: Any] {
        (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    /// A reasoning model as OpenAI serves it: no temperature, optionally no streaming.
    static func reasoningModel(verified: Bool) -> ScriptedTransport {
        ScriptedTransport { request in
            let body = body(request)
            if body["temperature"] != nil { return .status(400, body: temperatureRefusal) }
            if body["stream"] as? Bool == true, !verified { return .status(400, body: streamRefusal) }
            if body["stream"] as? Bool == true { return .lines(sseStream("Acta lista.")) }
            return .lines([#"{"model":"gpt-6-luna","choices":[{"message":{"content":"Acta lista."},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":3}}"#])
        }
    }

    static let synthesisRequest = GenerationRequest(
        model: "gpt-6-luna", instructions: "i", input: "x",
        options: GenerationOptions(temperature: 0.2, maxOutputTokens: 8_000))

    @Test("a refused temperature is left out and the request sent again")
    func temperatureDropped() async throws {
        let transport = Self.reasoningModel(verified: true)
        let provider = ChatCompletionsProvider.openAI(credentials: store, transport: transport)
        let outcome = await collect(provider.stream(Self.synthesisRequest))

        #expect(outcome.error == nil)
        #expect(outcome.result?.text == "Acta lista.")
        #expect(transport.requests.count == 2)
        #expect(Self.body(transport.requests[1])["temperature"] == nil)
        #expect(Self.body(transport.requests[1])["max_completion_tokens"] as? Int == 8_000)
    }

    @Test("an organisation that may not stream gets the whole answer at once")
    func unverifiedOrganisation() async throws {
        let transport = Self.reasoningModel(verified: false)
        let provider = ChatCompletionsProvider.openAI(credentials: store, transport: transport)
        let outcome = await collect(provider.stream(Self.synthesisRequest))

        #expect(outcome.error == nil)
        #expect(outcome.result?.text == "Acta lista.")
        #expect(outcome.result?.usage?.outputTokens == 3)
        #expect(outcome.result?.finishReason == .stop)
        let last = Self.body(transport.requests.last!)
        #expect(last["stream"] as? Bool == false)
        #expect(last["stream_options"] == nil)
    }

    @Test("other refusals are reported, not retried")
    func otherRefusalsNotRetried() async {
        let transport = ScriptedTransport(.status(400, body: #"{"error":{"message":"The model `gpt-9` does not exist","type":"invalid_request_error"}}"#))
        let provider = ChatCompletionsProvider.openAI(credentials: store, transport: transport)
        let outcome = await collect(provider.stream(Self.synthesisRequest))

        #expect(outcome.error?.code == .invalidRequest)
        #expect(transport.requests.count == 1)
    }
}
