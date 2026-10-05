import Foundation

/// A model the user can pick within a provider.
public struct ModelDescriptor: Sendable, Hashable, Identifiable {
    public var id: ModelID
    public var displayName: String
    /// Total tokens the model accepts (input + output), when the provider says.
    public var contextTokens: Int?
    /// Suggested by us for rewriting; the picker lists these first.
    public var isRecommended: Bool
    /// Published prices, when the model list carries them (OpenRouter does; OpenAI's
    /// does not). Feeds the picker's cost estimate and the bench's budget.
    public var pricing: ModelPricing?
    /// Who made the model — `anthropic` for `anthropic/claude-…` — when known. The
    /// bench uses it to refuse a judge from the graded model's own vendor.
    public var vendor: String?

    public init(id: ModelID, displayName: String? = nil, contextTokens: Int? = nil, isRecommended: Bool = false,
                pricing: ModelPricing? = nil, vendor: String? = nil) {
        self.id = id
        self.displayName = displayName ?? id.rawValue
        self.contextTokens = contextTokens
        self.isRecommended = isRecommended
        self.pricing = pricing
        self.vendor = vendor
    }
}

/// Prices in US dollars per million tokens.
public struct ModelPricing: Sendable, Hashable {
    public var inputPerMillion: Double
    public var outputPerMillion: Double

    public init(inputPerMillion: Double, outputPerMillion: Double) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
    }

    /// The cost of `usage`, in US dollars.
    public func cost(of usage: TokenUsage) -> Double {
        (Double(usage.inputTokens) * inputPerMillion + Double(usage.outputTokens) * outputPerMillion) / 1_000_000
    }
}

/// One generation: instructions, the text to work on, and optional worked
/// examples. Deliberately single-shot — rewriting a selection has no chat
/// history, and a contract without history is one every provider can honour.
///
/// The contract does not know what a "profile" is. The layer above composes
/// `instructions` and `examples` from one; providers only decide how to
/// represent them for their model (messages, a transcript, plain text).
public struct GenerationRequest: Sendable, Hashable {
    public var model: ModelID
    /// What to do — the system prompt.
    public var instructions: String
    /// The user's text. Always sent as data, never merged into `instructions`.
    public var input: String
    /// Input → output pairs that illustrate the expected transformation.
    public var examples: [Example]
    public var options: GenerationOptions

    public struct Example: Sendable, Hashable {
        public var input: String
        public var output: String
        public init(input: String, output: String) {
            self.input = input
            self.output = output
        }
    }

    public init(model: ModelID, instructions: String, input: String, examples: [Example] = [], options: GenerationOptions = .init()) {
        self.model = model
        self.instructions = instructions
        self.input = input
        self.examples = examples
        self.options = options
    }
}

public struct GenerationOptions: Sendable, Hashable {
    /// 0 = deterministic. `nil` leaves the provider's default.
    public var temperature: Double?
    /// The output limit. The on-device provider ignores it: the framework ends a
    /// capped answer early without saying so (PROVIDERS §8 item 4).
    public var maxOutputTokens: Int?
    /// Wall-clock limit for the whole generation.
    public var timeout: Duration

    public init(temperature: Double? = nil, maxOutputTokens: Int? = nil, timeout: Duration = .seconds(60)) {
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.timeout = timeout
    }
}

public struct GenerationResult: Sendable, Hashable {
    public var text: String
    public var provider: ProviderID
    /// The model that actually answered — aggregators may route elsewhere.
    public var model: ModelID
    public var usage: TokenUsage?
    public var latency: Duration
    /// Why the model stopped. A `length` answer was cut off by the output limit and
    /// looks complete; callers must never apply it (PROVIDERS §8 item 1).
    public var finishReason: FinishReason

    public init(text: String, provider: ProviderID, model: ModelID, usage: TokenUsage? = nil, latency: Duration,
                finishReason: FinishReason) {
        self.text = text
        self.provider = provider
        self.model = model
        self.usage = usage
        self.latency = latency
        self.finishReason = finishReason
    }
}

public enum FinishReason: String, Sendable, Hashable, Codable {
    /// The model ended its answer.
    case stop
    /// The output limit cut it off.
    case length
    /// A content filter ended it.
    case contentFilter
    /// The provider did not say.
    case unknown

    /// Chat Completions' `finish_reason` values.
    public init(chatCompletions value: String?) {
        switch value {
        case "stop", "end_turn", "stop_sequence": self = .stop
        case "length", "max_tokens": self = .length
        case "content_filter": self = .contentFilter
        default: self = .unknown
        }
    }
}

public struct TokenUsage: Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// What a streaming generation emits: text as it arrives, then exactly one
/// `completed` with the full result. A stream that ends without `completed`
/// either threw, or was cancelled by its consumer.
public enum GenerationEvent: Sendable, Hashable {
    case delta(String)
    case completed(GenerationResult)
}
