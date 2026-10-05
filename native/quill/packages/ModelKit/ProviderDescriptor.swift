import Foundation

/// Everything the app needs to know about a provider **without calling it**:
/// what to show in the model picker, what to warn about, what to ask for.
///
/// The advantages and drawbacks shown to the user are not free text. They are
/// derived from `traits` (facts that can be checked) plus a short list of
/// `notes` for what facts cannot express — model quality, catalogue size. That
/// way a provider cannot claim to be private while declaring that text leaves
/// the Mac: the two come from the same field.
public struct ProviderDescriptor: Sendable, Hashable {
    public var id: ProviderID
    /// Product name shown to the user. Not localized: brand names are not translated.
    public var displayName: String
    public var traits: ProviderTraits
    /// Qualitative tradeoffs the traits cannot express.
    public var notes: [Tradeoff]

    public init(id: ProviderID, displayName: String, traits: ProviderTraits, notes: [Tradeoff] = []) {
        self.id = id
        self.displayName = displayName
        self.traits = traits
        self.notes = notes
    }

    /// The full, ordered list the model picker renders: derived facts first,
    /// then the provider's notes, with duplicates removed.
    public var tradeoffs: [Tradeoff] {
        var seen = Set<Tradeoff>()
        return (traits.derivedTradeoffs + notes).filter { seen.insert($0).inserted }
    }

    public var advantages: [Tradeoff] { tradeoffs.filter(\.isAdvantage) }
    public var drawbacks: [Tradeoff] { tradeoffs.filter { !$0.isAdvantage } }
}

/// Checkable facts about a provider.
public struct ProviderTraits: Sendable, Hashable {
    public enum Execution: Sendable, Hashable {
        /// Inference runs on this Mac. Nothing leaves it.
        case onDevice
        /// Inference runs on someone else's servers. `recipients` names every
        /// party that receives the text, in order — an aggregator AND the
        /// final model vendor, not just the one the user signed up with.
        case remote(recipients: [Recipient])
    }

    public enum Cost: Sendable, Hashable {
        case free
        case payPerUse
    }

    public enum Credential: Sendable, Hashable {
        case none
        case apiKey
    }

    public var execution: Execution
    public var cost: Cost
    public var credential: Credential
    /// Largest context window among the provider's models, when known. Used
    /// for the "short texts only" warning.
    public var maxContextTokens: Int?

    public init(execution: Execution, cost: Cost, credential: Credential, maxContextTokens: Int? = nil) {
        self.execution = execution
        self.cost = cost
        self.credential = credential
        self.maxContextTokens = maxContextTokens
    }

    /// Below this, long documents need splitting and the picker says so.
    public static let smallContextThreshold = 8_192

    var derivedTradeoffs: [Tradeoff] {
        var result: [Tradeoff] = []
        switch execution {
        case .onDevice:
            result += [.staysOnDevice, .worksOffline]
        case .remote(let recipients):
            result += [.textLeavesDevice(recipients: recipients), .requiresNetwork]
        }
        switch cost {
        case .free: result.append(.free)
        case .payPerUse: result.append(.paidPerUse)
        }
        switch credential {
        case .none: result.append(.noAccountNeeded)
        case .apiKey: result.append(.requiresAPIKey)
        }
        if let tokens = maxContextTokens, tokens < Self.smallContextThreshold {
            result.append(.smallContext(tokens: tokens))
        }
        return result
    }
}

/// Who receives the text, as typed values the app localizes — never English strings
/// in data (PROVIDERS §8 item 7).
public enum Recipient: Sendable, Hashable {
    /// A company, by its brand name (not translated): "OpenRouter", "OpenAI".
    case named(String)
    /// The inference provider an aggregator routes the request to (OpenRouter).
    case routedInferenceProvider
    /// The provider that serves the chosen model behind a gateway (Vercel).
    case modelServingProvider
    /// A server the user configured, by host name.
    case host(String)
}

/// One line in the model picker's "pros and cons". The app maps each case to
/// localized copy; the contract only carries the meaning.
public enum Tradeoff: Sendable, Hashable {
    // Advantages
    case free
    case staysOnDevice
    case worksOffline
    case noAccountNeeded
    case unlimitedUse
    /// Hundreds of models from many vendors behind one key.
    case manyModels
    /// The text reaches only the model vendor, with no aggregator in between.
    case singleRecipient
    case strongModels

    // Drawbacks
    case paidPerUse
    case textLeavesDevice(recipients: [Recipient])
    case requiresNetwork
    case requiresAPIKey
    case smallContext(tokens: Int)
    /// A small model: more likely to over-edit, under-edit or alter meaning.
    case smallModel
    /// Needs a compatible Mac with Apple Intelligence turned on.
    case requiresAppleIntelligence
    /// Fewer supported languages than the large hosted models.
    case limitedLanguages
    /// Built-in content filters may refuse some texts.
    case mayRefuseContent
    /// Data handling depends on whichever vendor serves the chosen model.
    case dataPolicyVariesByModel
    /// Only one vendor's models (OpenAI's preset).
    case singleVendorCatalog
    /// A server on this Mac may itself forward the text elsewhere; privacy depends on
    /// what it does.
    case localServerMayForward

    public var isAdvantage: Bool {
        switch self {
        case .free, .staysOnDevice, .worksOffline, .noAccountNeeded, .unlimitedUse,
             .manyModels, .singleRecipient, .strongModels:
            true
        case .paidPerUse, .textLeavesDevice, .requiresNetwork, .requiresAPIKey, .smallContext,
             .smallModel, .requiresAppleIntelligence, .limitedLanguages, .mayRefuseContent,
             .dataPolicyVariesByModel, .singleVendorCatalog, .localServerMayForward:
            false
        }
    }
}
