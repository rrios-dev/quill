import Foundation

/// Stable identifier of a provider, e.g. `apple.on-device` or `openrouter`.
///
/// It is persisted (profiles store which provider they use), so it must never
/// change once shipped. Lowercase ASCII, digits, dots and dashes only — the
/// registry rejects anything else so a typo cannot become a stored value.
public struct ProviderID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }

    /// Whether the identifier follows the persisted format.
    public var isWellFormed: Bool {
        !rawValue.isEmpty && rawValue.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "." || $0 == "-") }
    }
}

/// Identifier of a model **as the provider names it**: `gpt-5.5`,
/// `anthropic/claude-sonnet-4.6`, `system`. Opaque to the contract.
public struct ModelID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }
}

/// What a profile (or any caller) stores to say "use this model": the pair is
/// the whole address, because model ids are only unique within a provider.
public struct ModelSelection: Hashable, Codable, Sendable {
    public var provider: ProviderID
    public var model: ModelID

    public init(provider: ProviderID, model: ModelID) {
        self.provider = provider
        self.model = model
    }
}
