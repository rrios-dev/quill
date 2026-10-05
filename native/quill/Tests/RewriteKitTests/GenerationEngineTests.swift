import Foundation
import ModelKit
import Testing

@testable import RewriteKit

/// A provider that answers from a script and counts what it was asked.
final class ScriptedModelProvider: ModelProvider, @unchecked Sendable {
    enum Reply: Sendable {
        case text(String, FinishReason)
        case error(ProviderError.Code)
        case hang
    }

    let descriptor = ProviderDescriptor(
        id: "scripted", displayName: "Scripted",
        traits: ProviderTraits(execution: .remote(recipients: [.named("Scripted")]), cost: .payPerUse, credential: .none))
    private let reply: Reply
    private let available: ProviderAvailability
    private let lock = NSLock()
    private var streams = 0
    private var generates = 0
    private(set) var lastRequest: GenerationRequest?

    init(_ reply: Reply, available: ProviderAvailability = .available) {
        self.reply = reply
        self.available = available
    }

    var streamCalls: Int { lock.withLock { streams } }
    var generateCalls: Int { lock.withLock { generates } }

    func availability() async -> ProviderAvailability { available }
    func models() async throws -> [ModelDescriptor] { [] }

    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error> {
        lock.withLock { streams += 1; lastRequest = request }
        let reply = reply
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch reply {
                case .text(let text, let finish):
                    for word in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
                        continuation.yield(.delta(word.offset == 0 ? String(word.element) : " " + word.element))
                    }
                    continuation.yield(.completed(GenerationResult(
                        text: text, provider: "scripted", model: request.model, latency: .milliseconds(5), finishReason: finish)))
                    continuation.finish()
                case .error(let code):
                    continuation.finish(throwing: ProviderError(code, "scripted", provider: "scripted"))
                case .hang:
                    try? await Task.sleep(for: .seconds(3600))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        lock.withLock { generates += 1; lastRequest = request }
        switch reply {
        case .text(let text, let finish):
            return GenerationResult(text: text, provider: "scripted", model: request.model, latency: .zero, finishReason: finish)
        case .error(let code):
            throw ProviderError(code, "scripted", provider: "scripted")
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            throw ProviderError(.cancelled, "cancelled", provider: "scripted")
        }
    }
}

final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [GenerationState] = []
    func append(_ state: GenerationState) { lock.withLock { states.append(state) } }
    var all: [GenerationState] { lock.withLock { states } }
}

@Suite("Generation engine")
struct GenerationEngineTests {
    let engine: GenerationEngine
    let profile: Profile

    init() throws {
        engine = try GenerationEngine()
        profile = Profile(name: "Work", symbol: "briefcase", settings: ProfileSettings(scope: .rewrite, preserve: []))
    }

    private let input = "hey so the report you asked for is not done yet sorry"
    private let model = ModelSelection(provider: "scripted", model: "m")

    private func run(_ reply: ScriptedModelProvider.Reply, input: String? = nil, context: Int? = 128_000,
                     streams: Bool = true, available: ProviderAvailability = .available,
                     alternatives: [ModelCandidate] = [], onDevice: Bool = false) async -> (GenerationEngine.Outcome, ScriptedModelProvider, [GenerationState]) {
        let provider = ScriptedModelProvider(reply, available: available)
        let log = StateLog()
        let outcome = await engine.run(
            .init(profile: profile, input: input ?? self.input, model: model, contextTokens: context,
                  runsOnDevice: onDevice, alternatives: alternatives, streams: streams),
            provider: provider, onUpdate: { log.append($0) })
        return (outcome, provider, log.all)
    }

    @Test("a complete answer becomes ready, streaming its partial text first")
    func ready() async {
        let (outcome, provider, states) = await run(.text("The report you asked for is not done yet. Sorry.", .stop))
        #expect(outcome.state == .ready(text: "The report you asked for is not done yet. Sorry.", flags: []))
        #expect(states.contains(.generating(partial: "The")))
        #expect(states.last == outcome.state)
        #expect(provider.streamCalls == 1)
        #expect(provider.lastRequest?.input == input, "the input travels as its own message")
    }

    @Test("edge whitespace is set aside before generating and re-attached to the result")
    func edgesReattached() async {
        let (outcome, provider, _) = await run(.text("The report is not done yet.", .stop), input: "\n  the report is not done yet\n")
        #expect(provider.lastRequest?.input == "the report is not done yet")
        #expect(outcome.state == .ready(text: "\n  The report is not done yet.\n", flags: []))
    }

    @Test("a length finish is truncated, keeping the partial text for display")
    func truncated() async {
        let (outcome, _, _) = await run(.text("The report you", .length))
        #expect(outcome.state == .truncated(partial: "The report you"))
    }

    @Test("a contentFilter finish is a refusal")
    func contentFilter() async {
        #expect(await run(.text("", .contentFilter)).0.state == .refused)
    }

    @Test("a refusal in text (G10) is a refusal")
    func refusalText() async {
        #expect(await run(.text("I'm sorry, but I can't help with that request.", .stop)).0.state == .refused)
    }

    @Test("ProviderError.refused is a refusal; .cancelled is cancelled")
    func refusedAndCancelledCodes() async {
        #expect(await run(.error(.refused)).0.state == .refused)
        #expect(await run(.error(.cancelled)).0.state == .cancelled)
    }

    @Test("every other code fails with that code", arguments: [
        ProviderError.Code.authentication, .rateLimited(retryAfter: nil), .contextExceeded,
        .unavailable(.modelNotReady), .network, .timeout, .server, .malformedResponse, .invalidRequest,
    ])
    func otherCodesFail(_ code: ProviderError.Code) async {
        #expect(await run(.error(code)).0.state == .failed(code, partial: ""))
    }

    @Test("the output equal to the input is no changes (G7)")
    func noChanges() async {
        #expect(await run(.text(input, .stop)).0.state == .noChanges)
    }

    @Test("an answer that is only a preamble fails as malformed (G8)")
    func emptyAfterPreamble() async {
        #expect(await run(.text("Corrected text:\n", .stop)).0.state == .failed(.malformedResponse, partial: ""))
    }

    @Test("flags reach the ready state")
    func flagged() async {
        let (outcome, _, _) = await run(.text("Hi [name], the report you asked for is not done yet. Sorry.", .stop))
        guard case .ready(_, let flags) = outcome.state else { Issue.record("\(outcome.state)"); return }
        #expect(flags.contains { $0.guardID == "G2" })
    }

    @Test("a text too long for the model is tooLong without reaching the provider")
    func tooLong() async {
        let long = String(repeating: "word ", count: 3_000)
        let (outcome, provider, _) = await run(.text("x", .stop), input: long, context: 4_096)
        guard case .tooLong = outcome.state else { Issue.record("\(outcome.state)"); return }
        #expect(provider.streamCalls == 0 && provider.generateCalls == 0)
        #expect((outcome.requiredTokens ?? 0) > 4_096)
    }

    @Test("the too-long suggestion names a model that fits, and only local ones for an on-device model")
    func tooLongSuggestion() async {
        let long = String(repeating: "word ", count: 3_000)
        let hosted = ModelCandidate(selection: ModelSelection(provider: "openrouter", model: "big"), contextTokens: 200_000, runsOnDevice: false)
        let local = ModelCandidate(selection: ModelSelection(provider: "ollama", model: "local"), contextTokens: 32_000, runsOnDevice: true)
        let small = ModelCandidate(selection: ModelSelection(provider: "ollama", model: "tiny"), contextTokens: 2_048, runsOnDevice: true)

        let fromHosted = await run(.text("x", .stop), input: long, context: 4_096, alternatives: [small, hosted, local])
        #expect(fromHosted.0.state == .tooLong(suggestion: hosted.selection))

        let fromDevice = await run(.text("x", .stop), input: long, context: 4_096, alternatives: [hosted, small, local], onDevice: true)
        #expect(fromDevice.0.state == .tooLong(suggestion: local.selection), "never a hosted model for an on-device one")

        let nothingFits = await run(.text("x", .stop), input: long, context: 4_096, alternatives: [small], onDevice: true)
        #expect(nothingFits.0.state == .tooLong(suggestion: nil))
    }

    @Test("an unavailable provider fails before anything is composed or sent")
    func unavailable() async {
        let (outcome, provider, _) = await run(.text("x", .stop), available: .unavailable(.missingCredential))
        #expect(outcome.state == .failed(.unavailable(.missingCredential), partial: ""))
        #expect(provider.streamCalls == 0)
    }

    @Test("one-shot mode uses generate, not stream")
    func oneShot() async {
        let (outcome, provider, _) = await run(.text("The report you asked for is not done yet. Sorry.", .stop), streams: false)
        #expect(provider.generateCalls == 1 && provider.streamCalls == 0)
        #expect(outcome.state == .ready(text: "The report you asked for is not done yet. Sorry.", flags: []))
    }

    @Test("cancelling the consuming task ends in cancelled")
    func taskCancellation() async {
        let provider = ScriptedModelProvider(.hang)
        let engine = engine
        let profile = profile
        let input = input
        let model = model
        let task = Task {
            await engine.run(.init(profile: profile, input: input, model: model, contextTokens: 128_000, runsOnDevice: false),
                             provider: provider).state
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        #expect(await task.value == .cancelled)
    }
}
