import Foundation

/// The contract every model provider implements.
///
/// Adding a provider means conforming one type to this protocol and
/// registering it. Nothing above the contract — profiles, the picker, the
/// rewrite flow — changes. Three rules every conformance keeps, checked by the
/// shared contract suite in the tests:
///
/// 1. **Errors are `ProviderError`.** Callers switch on `code`, never on a
///    vendor's error type or HTTP status.
/// 2. **Cancellation is honoured.** Cancelling the consuming task stops the
///    work. A cancelled stream simply ends — Swift's `AsyncThrowingStream`
///    finishes iteration instead of throwing — so it ends with neither
///    `.completed` nor an error; `generate` turns that into `.cancelled`.
///    Cancellation is never reported as a failure.
/// 3. **Credentials come from the injected `CredentialStore`**, read at call
///    time, so a key added in Settings works without rebuilding providers.
public protocol ModelProvider: Sendable {
    var descriptor: ProviderDescriptor { get }

    /// Whether the provider can be used right now. Cheap: no generation, and
    /// for remote providers no network call — a missing key is enough to say no.
    func availability() async -> ProviderAvailability

    /// Models the user can pick. May hit the network; callers cache.
    func models() async throws -> [ModelDescriptor]

    /// Streams a generation. The stream finishes after one `.completed`, throws
    /// a `ProviderError`, or — only when the consumer cancelled — just ends.
    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error>

    /// One-shot generation. A requirement — not only an extension — so a provider can
    /// answer it without streaming (the on-device one uses the framework's `respond`)
    /// and calls through `any ModelProvider` reach that implementation. The default
    /// collects `stream`.
    func generate(_ request: GenerationRequest) async throws -> GenerationResult

    /// Prepares for a request whose input is not known yet — `request.input` is
    /// ignored. Called when the hot key is pressed; the default does nothing.
    func prewarm(for request: GenerationRequest) async

    /// Estimated tokens of `request` (instructions, examples and input) for the
    /// context pre-check. The default counts characters ÷ 3.5.
    func estimateTokens(_ request: GenerationRequest) async -> Int
}

extension ModelProvider {
    public var id: ProviderID { descriptor.id }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        try await collectStream(request)
    }

    /// The stream-based `generate`, callable by providers that override it.
    public func collectStream(_ request: GenerationRequest) async throws -> GenerationResult {
        for try await event in stream(request) {
            if case .completed(let result) = event { return result }
        }
        if Task.isCancelled { throw ProviderError(.cancelled, "Cancelled.", provider: id) }
        throw ProviderError(.malformedResponse, "The stream ended without a result.", provider: id)
    }

    public func prewarm(for request: GenerationRequest) async {}

    public func estimateTokens(_ request: GenerationRequest) async -> Int {
        TokenEstimate.characters(in: request)
    }
}

/// The fallback token estimate: characters ÷ 3.5, rounded up. Precise enough for a
/// pre-check that keeps a 1.3× output reserve; providers with a tokenizer do better.
public enum TokenEstimate {
    public static let charactersPerToken = 3.5

    public static func characters(in request: GenerationRequest) -> Int {
        let characters = request.instructions.count + request.input.count
            + request.examples.reduce(0) { $0 + $1.input.count + $1.output.count }
        return Int((Double(characters) / charactersPerToken).rounded(.up))
    }
}

public enum ProviderAvailability: Sendable, Hashable {
    case available
    case unavailable(UnavailableReason)

    public var isAvailable: Bool { self == .available }
}

public enum UnavailableReason: Sendable, Hashable {
    /// The provider needs an API key and none is stored.
    case missingCredential
    /// This Mac cannot run the model at all.
    case deviceNotEligible
    /// The Mac can, but Apple Intelligence is turned off in System Settings.
    case appleIntelligenceDisabled
    /// The model is still downloading or preparing.
    case modelNotReady
    /// Built without the framework the provider needs.
    case unsupportedPlatform
}
