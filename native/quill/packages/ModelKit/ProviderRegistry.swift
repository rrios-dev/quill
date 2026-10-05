import Foundation

/// The set of providers the app offers, keyed by id.
///
/// Built once at launch from an explicit list. There is no runtime discovery:
/// the list of providers is a product decision, and a registry that cannot be
/// modified after launch is one the UI can trust.
public struct ProviderRegistry: Sendable {
    public let providers: [any ModelProvider]
    private let index: [ProviderID: Int]

    public init(_ providers: [any ModelProvider]) throws {
        var index: [ProviderID: Int] = [:]
        for (offset, provider) in providers.enumerated() {
            let id = provider.descriptor.id
            guard id.isWellFormed else { throw RegistryError.malformedID(id) }
            guard index[id] == nil else { throw RegistryError.duplicateID(id) }
            index[id] = offset
        }
        self.providers = providers
        self.index = index
    }

    public subscript(id: ProviderID) -> (any ModelProvider)? {
        index[id].map { providers[$0] }
    }

    public var descriptors: [ProviderDescriptor] { providers.map(\.descriptor) }

    /// Resolves a stored selection, failing with the same error a provider
    /// would raise so callers handle one error type.
    public func provider(for selection: ModelSelection) throws -> any ModelProvider {
        guard let provider = self[selection.provider] else {
            throw ProviderError(.invalidRequest, "Unknown provider '\(selection.provider)'.", provider: selection.provider)
        }
        return provider
    }

    /// Runs a generation for a stored selection.
    public func stream(_ selection: ModelSelection, instructions: String, input: String,
                       examples: [GenerationRequest.Example] = [], options: GenerationOptions = .init()) throws
        -> AsyncThrowingStream<GenerationEvent, any Error>
    {
        let request = GenerationRequest(model: selection.model, instructions: instructions, input: input,
                                        examples: examples, options: options)
        return try provider(for: selection).stream(request)
    }
}

public enum RegistryError: Error, Sendable, Hashable {
    case duplicateID(ProviderID)
    case malformedID(ProviderID)
}
