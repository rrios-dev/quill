import Foundation
import ModelKit

/// The states one generation goes through (ARCHITECTURE §2, "State ownership").
///
/// Partial text (generating, truncated, failed) is for display only: it is never copied
/// or applied.
public enum GenerationState: Hashable, Sendable {
    case idle
    case generating(partial: String)
    /// A result. With flags it is "Flagged" in the picker and needs ⌘Return.
    case ready(text: String, flags: [GuardFlag])
    case noChanges
    /// The output limit cut the answer off.
    case truncated(partial: String)
    case refused
    /// The text does not fit the model; `suggestion` names one that fits, if any.
    case tooLong(suggestion: ModelSelection?)
    case failed(ProviderError.Code, partial: String)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .idle, .generating: false
        default: true
        }
    }
}

/// A model the too-long suggestion may name (ARCHITECTURE §4.4).
public struct ModelCandidate: Hashable, Sendable {
    public var selection: ModelSelection
    public var contextTokens: Int
    /// On this Mac: the on-device model or a loopback server.
    public var runsOnDevice: Bool

    public init(selection: ModelSelection, contextTokens: Int, runsOnDevice: Bool) {
        self.selection = selection
        self.contextTokens = contextTokens
        self.runsOnDevice = runsOnDevice
    }
}

/// Drives one generation (ARCHITECTURE §4.5): edge whitespace trimmed and re-attached,
/// availability → pre-check → compose → generate → finish reason → guards → a terminal
/// state.
public struct GenerationEngine: Sendable {
    public struct Request: Sendable {
        public var profile: Profile
        /// The captured selection, as captured.
        public var input: String
        public var model: ModelSelection
        /// The model's context size; picks the prompt strategy and bounds the pre-check.
        public var contextTokens: Int?
        /// Whether the resolved model runs on this Mac — the too-long suggestion then
        /// names only models that do too, so a rerun never sends the text elsewhere.
        public var runsOnDevice: Bool
        public var formatting: CaptureFormatting
        /// The bench's `exampleBait` example (BENCH §2.1).
        public var pinnedExample: Example?
        /// Models the too-long suggestion may name, in order of preference.
        public var alternatives: [ModelCandidate]
        /// Stream (the picker) or one-shot `generate` (the bench, PROVIDERS §8 item 4).
        public var streams: Bool
        /// The output cap the bench puts on hosted calls (BENCH §3); nil leaves the
        /// provider's default.
        public var maxOutputTokens: Int?
        /// A one-off instruction typed in the picker (`PromptComposer.compose`).
        public var instruction: String?

        public init(profile: Profile, input: String, model: ModelSelection, contextTokens: Int?,
                    runsOnDevice: Bool, formatting: CaptureFormatting = .plain, pinnedExample: Example? = nil,
                    alternatives: [ModelCandidate] = [], streams: Bool = true, maxOutputTokens: Int? = nil,
                    instruction: String? = nil) {
            self.profile = profile
            self.input = input
            self.model = model
            self.contextTokens = contextTokens
            self.runsOnDevice = runsOnDevice
            self.formatting = formatting
            self.pinnedExample = pinnedExample
            self.alternatives = alternatives
            self.streams = streams
            self.maxOutputTokens = maxOutputTokens
            self.instruction = instruction
        }
    }

    /// The terminal state, with what led to it.
    public struct Outcome: Sendable {
        public var state: GenerationState
        public var prompt: ComposedPrompt?
        public var result: GenerationResult?
        /// What G1 removed from the model's answer.
        public var stripped: String?
        /// Tokens the pre-check required (instructions, examples, input and the reserve).
        public var requiredTokens: Int?
    }

    /// The output reserve of the pre-check, as a multiple of the input's tokens.
    public static let outputReserve = 1.3

    let composer: PromptComposer
    let guards: OutputGuards

    public init(composer: PromptComposer, guards: OutputGuards) {
        self.composer = composer
        self.guards = guards
    }

    public init() throws {
        try self.init(composer: PromptComposer(), guards: OutputGuards())
    }

    public func run(
        _ request: Request,
        provider: any ModelProvider,
        onUpdate: @Sendable (GenerationState) -> Void = { _ in }
    ) async -> Outcome {
        // Edge whitespace (a triple-click's final line break) is set aside, so it neither
        // distorts the guards nor merges paragraphs on paste, and re-attached at the end.
        let (leading, core, trailing) = Self.splitEdges(request.input)

        if case .unavailable(let reason) = await provider.availability() {
            return finish(.failed(.unavailable(reason), partial: ""), onUpdate)
        }
        if Task.isCancelled { return finish(.cancelled, onUpdate) }

        var prompt = await composer.compose(
            profile: request.profile, input: core, model: request.model.model,
            contextTokens: request.contextTokens, pinnedExample: request.pinnedExample,
            instruction: request.instruction,
            estimate: { text in await provider.estimateTokens(GenerationRequest(model: request.model.model, instructions: "", input: text)) })

        prompt.request.options.maxOutputTokens = request.maxOutputTokens

        // Pre-check: instructions + examples + input, plus room for the answer.
        let promptTokens = await provider.estimateTokens(prompt.request)
        let inputTokens = await provider.estimateTokens(GenerationRequest(model: request.model.model, instructions: "", input: core))
        let required = promptTokens + Int((Double(inputTokens) * Self.outputReserve).rounded(.up))
        if let context = request.contextTokens, required > context {
            var outcome = finish(.tooLong(suggestion: suggestion(for: request, required: required)), onUpdate)
            outcome.prompt = prompt
            outcome.requiredTokens = required
            return outcome
        }

        var partial = ""
        let result: GenerationResult
        do {
            if request.streams {
                var completed: GenerationResult?
                for try await event in provider.stream(prompt.request) {
                    switch event {
                    case .delta(let text):
                        partial += text
                        onUpdate(.generating(partial: partial))
                    case .completed(let value):
                        completed = value
                    }
                }
                guard let completed else {
                    let state: GenerationState = Task.isCancelled ? .cancelled : .failed(.malformedResponse, partial: partial)
                    return outcome(state, prompt: prompt, required: required, onUpdate)
                }
                result = completed
            } else {
                result = try await provider.generate(prompt.request)
            }
        } catch let error as ProviderError {
            let state: GenerationState = switch error.code {
            case .refused: .refused
            case .cancelled: .cancelled
            default: .failed(error.code, partial: partial)
            }
            return outcome(state, prompt: prompt, required: required, onUpdate)
        } catch {
            let state: GenerationState = Task.isCancelled ? .cancelled : .failed(.server, partial: partial)
            return outcome(state, prompt: prompt, required: required, onUpdate)
        }

        switch result.finishReason {
        case .length:
            return outcome(.truncated(partial: result.text), prompt: prompt, result: result, required: required, onUpdate)
        case .contentFilter:
            return outcome(.refused, prompt: prompt, result: result, required: required, onUpdate)
        case .stop, .unknown:
            break
        }

        let sentExamples = (request.pinnedExample.map { [$0] } ?? [])
            + request.profile.examples.filter { prompt.report.sentExamples.contains($0.id) }
        let checked = guards.evaluate(
            input: core, output: result.text,
            context: .init(settings: request.profile.settings, examples: sentExamples, formatting: request.formatting))
        let state: GenerationState = switch checked.verdict {
        case .result(let text, let flags): .ready(text: leading + text + trailing, flags: flags)
        case .noChanges: .noChanges
        case .empty: .failed(.malformedResponse, partial: "")
        case .refused: .refused
        }
        var final = outcome(state, prompt: prompt, result: result, required: required, onUpdate)
        final.stripped = checked.stripped
        return final
    }

    /// The single definition of the too-long suggestion (ARCHITECTURE §4.4): the first
    /// alternative whose context fits, restricted to on-device and local models when the
    /// resolved model runs on this Mac; none when nothing fits.
    func suggestion(for request: Request, required: Int) -> ModelSelection? {
        request.alternatives.first { candidate in
            candidate.selection != request.model
                && candidate.contextTokens >= required
                && (!request.runsOnDevice || candidate.runsOnDevice)
        }?.selection
    }

    static func splitEdges(_ text: String) -> (leading: String, core: String, trailing: String) {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
              let last = text.lastIndex(where: { !$0.isWhitespace }) else { return (text, "", "") }
        return (String(text[..<first]), String(text[first...last]), String(text[text.index(after: last)...]))
    }

    private func finish(_ state: GenerationState, _ onUpdate: (GenerationState) -> Void) -> Outcome {
        onUpdate(state)
        return Outcome(state: state, prompt: nil, result: nil, stripped: nil, requiredTokens: nil)
    }

    private func outcome(
        _ state: GenerationState, prompt: ComposedPrompt, result: GenerationResult? = nil, required: Int,
        _ onUpdate: (GenerationState) -> Void
    ) -> Outcome {
        onUpdate(state)
        return Outcome(state: state, prompt: prompt, result: result, stripped: nil, requiredTokens: required)
    }
}
