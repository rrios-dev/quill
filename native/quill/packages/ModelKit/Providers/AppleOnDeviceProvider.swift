import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Apple Intelligence's on-device model through the Foundation Models framework.
///
/// Free, unlimited, offline, and the text never leaves the Mac. The price is a
/// small model (~3B parameters, 4,096-token context) that, measured on
/// 2026-10-03, over-edited, under-edited and once altered meaning (the
/// consuming app's planning documents record the measurement). It is offered
/// as a choice, with those drawbacks shown, not as the default for every
/// profile.
///
/// Private Cloud Compute is deliberately absent: Apple grants that entitlement
/// only to App Store apps, and this app ships outside the store.
///
/// How it uses the framework (PROVIDERS §8 item 4):
/// - **Permissive guardrails** (`permissiveContentTransformations`), Apple's mode for
///   transforming text the user supplied. In it the model may answer with a refusal
///   *as text* instead of throwing; the caller's refusal guard catches that.
/// - **No output cap.** The framework ends a capped answer early without an error, so
///   a cut-off answer would look complete. `GenerationOptions.maxOutputTokens` is
///   ignored; the caller's context pre-check keeps room for the answer instead.
/// - **Single-use sessions.** A session keeps its transcript, so reusing one would
///   carry the previous selection into the next prompt. `prewarm(for:)` builds one
///   session for the next matching request; it is used once and discarded.
/// - **One retry when rate-limited**, after a backoff, on a fresh session.
public struct AppleOnDeviceProvider: ModelProvider {
    public static let providerID: ProviderID = "apple.on-device"
    /// The framework exposes one model; this is the id profiles store for it.
    public static let modelID: ModelID = "system"
    /// The backoff before the single rate-limit retry.
    public static let rateLimitBackoff: Duration = .seconds(1)

    public let descriptor: ProviderDescriptor
    private let prewarmed = SingleUseStore<PrewarmKey, SessionBox>()
    private let onRetry: (@Sendable () -> Void)?

    /// - Parameter onRetry: called when a generation is retried after rate limiting —
    ///   for measuring how often the framework throttles (Debug → Live provider test).
    public init(onRetry: (@Sendable () -> Void)? = nil) {
        self.onRetry = onRetry
        descriptor = ProviderDescriptor(
            id: Self.providerID,
            displayName: "Apple Intelligence",
            traits: ProviderTraits(execution: .onDevice, cost: .free, credential: .none,
                                   maxContextTokens: Self.makeModel().contextSize),
            notes: [.unlimitedUse, .smallModel, .requiresAppleIntelligence, .limitedLanguages, .mayRefuseContent])
    }

    /// The model, configured for rewriting the user's own text.
    static func makeModel() -> SystemLanguageModel {
        SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    public func availability() async -> ProviderAvailability {
        Self.map(Self.makeModel().availability)
    }

    public func models() async throws -> [ModelDescriptor] {
        [ModelDescriptor(id: Self.modelID, displayName: "Apple Intelligence",
                         contextTokens: Self.makeModel().contextSize, isRecommended: true, vendor: "apple")]
    }

    // MARK: Prewarm and estimates

    public func prewarm(for request: GenerationRequest) async {
        guard request.model == Self.modelID, Self.makeModel().isAvailable else { return }
        let session = Self.session(for: request)
        session.prewarm()
        await prewarmed.put(SessionBox(session), for: PrewarmKey(request))
    }

    public func estimateTokens(_ request: GenerationRequest) async -> Int {
        if #available(macOS 26.4, *) {
            var entries = Array(Self.transcript(for: request))
            entries.append(.prompt(Transcript.Prompt(segments: Self.text(request.input))))
            if let count = try? await Self.makeModel().tokenCount(for: entries) { return count }
        }
        return TokenEstimate.characters(in: request)
    }

    // MARK: Generation

    public func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error> {
        let provider = Self.providerID
        return GenerationStream.make(provider: provider, timeout: request.options.timeout) { continuation in
            try Self.validate(request)
            let started = ContinuousClock.now
            let session = await takeSession(for: request)
            var emitted = ""
            do {
                // Snapshots are cumulative; the contract emits deltas.
                for try await snapshot in session.streamResponse(to: request.input, options: Self.options(request)) {
                    try Task.checkCancellation()
                    let content = snapshot.content
                    if content.hasPrefix(emitted) {
                        let delta = String(content.dropFirst(emitted.count))
                        if !delta.isEmpty { continuation.yield(.delta(delta)) }
                    }
                    emitted = content
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                let mapped = Self.map(error)
                // Rate limiting arrives before any text; only then can a retry replace
                // the answer without the consumer having seen half of another one.
                guard case .rateLimited = mapped.code, emitted.isEmpty else { throw mapped }
                emitted = try await retryAfterRateLimit(request)
                continuation.yield(.delta(emitted))
            }
            try Task.checkCancellation()
            continuation.yield(.completed(Self.result(emitted, started: started)))
        }
    }

    /// Non-streaming generation with the framework's `respond`: a background process
    /// (a command-line tool, an agent app behind a non-activating panel) may be
    /// throttled when it streams (PROVIDERS §8 item 4, BENCH intro).
    public func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        let stream = GenerationStream.make(provider: Self.providerID, timeout: request.options.timeout) { continuation in
            try Self.validate(request)
            let started = ContinuousClock.now
            let session = await takeSession(for: request)
            let text: String
            do {
                text = try await session.respond(to: request.input, options: Self.options(request)).content
            } catch let error as CancellationError {
                throw error
            } catch {
                let mapped = Self.map(error)
                guard case .rateLimited = mapped.code else { throw mapped }
                text = try await retryAfterRateLimit(request)
            }
            try Task.checkCancellation()
            continuation.yield(.completed(Self.result(text, started: started)))
        }
        return try await collect(stream)
    }

    private func collect(_ stream: AsyncThrowingStream<GenerationEvent, any Error>) async throws -> GenerationResult {
        for try await event in stream {
            if case .completed(let result) = event { return result }
        }
        if Task.isCancelled { throw ProviderError(.cancelled, "Cancelled.", provider: Self.providerID) }
        throw ProviderError(.malformedResponse, "The generation ended without a result.", provider: Self.providerID)
    }

    /// One retry, after the backoff, on a **fresh** session — whether the failed
    /// prompt stays in the old session's transcript is not documented — with the
    /// non-streaming `respond`. A second rate limit is surfaced to the caller.
    private func retryAfterRateLimit(_ request: GenerationRequest) async throws -> String {
        onRetry?()
        try await Task.sleep(for: Self.rateLimitBackoff)
        do {
            return try await Self.session(for: request).respond(to: request.input, options: Self.options(request)).content
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Self.map(error)
        }
    }

    private func takeSession(for request: GenerationRequest) async -> LanguageModelSession {
        await prewarmed.take(PrewarmKey(request))?.session ?? Self.session(for: request)
    }

    private static func validate(_ request: GenerationRequest) throws {
        guard request.model == modelID else {
            throw ProviderError(.invalidRequest, "Unknown model '\(request.model)'.", provider: providerID)
        }
        if case .unavailable(let reason) = map(makeModel().availability) {
            throw ProviderError(.unavailable(reason), "Apple Intelligence is not available.", provider: providerID)
        }
    }

    private static func session(for request: GenerationRequest) -> LanguageModelSession {
        LanguageModelSession(model: makeModel(), transcript: transcript(for: request))
    }

    /// Temperature only: `maximumResponseTokens` is never set (see the type's comment).
    static func options(_ request: GenerationRequest) -> FoundationModels.GenerationOptions {
        var options = FoundationModels.GenerationOptions()
        options.temperature = request.options.temperature
        return options
    }

    private static func result(_ text: String, started: ContinuousClock.Instant) -> GenerationResult {
        // The framework reports no finish reason. Without an output cap, an answer
        // ends because the model ended it or because the context overflowed — which
        // throws — so a completed answer is a whole one.
        GenerationResult(text: text, provider: providerID, model: modelID, latency: started.elapsed, finishReason: .stop)
    }

    private static func text(_ content: String) -> [Transcript.Segment] {
        [.text(Transcript.TextSegment(content: content))]
    }

    /// Instructions, then each example as a real prompt/response turn. Earlier
    /// trials that inlined examples into the instructions saw the model return
    /// the example instead of rewriting the input.
    static func transcript(for request: GenerationRequest) -> Transcript {
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: text(request.instructions), toolDefinitions: [])),
        ]
        for example in request.examples {
            entries.append(.prompt(Transcript.Prompt(segments: text(example.input))))
            entries.append(.response(Transcript.Response(assetIDs: [], segments: text(example.output))))
        }
        return Transcript(entries: entries)
    }

    // MARK: Mapping

    static func map(_ availability: SystemLanguageModel.Availability) -> ProviderAvailability {
        switch availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailable(.appleIntelligenceDisabled)
        case .unavailable(.modelNotReady): return .unavailable(.modelNotReady)
        case .unavailable: return .unavailable(.modelNotReady)
        }
    }

    /// Every framework error onto the contract: macOS 26's `GenerationError`, and
    /// macOS 27's replacements behind `#available` — without them a context overflow
    /// on macOS 27 would surface as a generic server error.
    static func map(_ error: any Error) -> ProviderError {
        if let error = error as? ProviderError { return error }
        #if compiler(>=6.4)
        if #available(macOS 27, *), let code = macOS27Code(for: error) {
            return ProviderError(code, error.localizedDescription, provider: providerID)
        }
        #endif
        if let error = error as? LanguageModelSession.GenerationError {
            return map(error)
        }
        return ProviderError.normalize(error, provider: providerID)
    }

    // The macOS 27 types exist only in the macOS 27 SDK, which comes with Xcode 27 (Swift
    // 6.4). An older Xcode — a CI runner without Xcode 27 — still builds Quill, mapping
    // those errors through `ProviderError.normalize`; releases are built with Xcode 27.
    #if compiler(>=6.4)
    @available(macOS 27, *)
    static func macOS27Code(for error: any Error) -> ProviderError.Code? {
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: return .contextExceeded
            case .rateLimited: return .rateLimited(retryAfter: nil)
            case .guardrailViolation, .refusal: return .refused
            case .timeout: return .timeout
            case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide,
                 .unsupportedLanguageOrLocale:
                return .invalidRequest
            @unknown default: return .server
            }
        }
        if let error = error as? SystemLanguageModel.Error {
            switch error {
            case .assetsUnavailable: return .unavailable(.modelNotReady)
            @unknown default: return .server
            }
        }
        if let error = error as? LanguageModelSession.Error {
            switch error {
            case .concurrentRequests: return .rateLimited(retryAfter: nil)
            case .transcriptMutationWhileResponding: return .invalidRequest
            @unknown default: return .server
            }
        }
        if error is GeneratedContent.ParsingError { return .malformedResponse }
        return nil
    }
    #endif

    static func map(_ error: LanguageModelSession.GenerationError) -> ProviderError {
        let code: ProviderError.Code = switch error {
        case .exceededContextWindowSize: .contextExceeded
        case .guardrailViolation, .refusal: .refused
        case .assetsUnavailable: .unavailable(.modelNotReady)
        case .rateLimited, .concurrentRequests: .rateLimited(retryAfter: nil)
        case .unsupportedLanguageOrLocale, .unsupportedGuide: .invalidRequest
        case .decodingFailure: .malformedResponse
        @unknown default: .server
        }
        return ProviderError(code, error.localizedDescription, provider: providerID)
    }
}

/// What a prewarmed session was built from: the request without its input.
struct PrewarmKey: Hashable, Sendable {
    let model: ModelID
    let instructions: String
    let examples: [GenerationRequest.Example]

    init(_ request: GenerationRequest) {
        model = request.model
        instructions = request.instructions
        examples = request.examples
    }
}

/// `LanguageModelSession` is a reference type the framework marks `@unchecked
/// Sendable`; the box only carries it into the store.
struct SessionBox: @unchecked Sendable {
    let session: LanguageModelSession
    init(_ session: LanguageModelSession) { self.session = session }
}
#endif

/// Holds values that may be taken **once**: a matching `take` removes the value, and a
/// new `put` replaces whatever was there. Prewarmed sessions use it so no session ever
/// serves two generations.
actor SingleUseStore<Key: Hashable & Sendable, Value: Sendable> {
    private var slot: (key: Key, value: Value)?

    func put(_ value: Value, for key: Key) {
        slot = (key, value)
    }

    func take(_ key: Key) -> Value? {
        guard let slot, slot.key == key else { return nil }
        self.slot = nil
        return slot.value
    }
}
