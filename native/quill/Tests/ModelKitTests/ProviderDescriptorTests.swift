import Foundation
import Testing

@testable import ModelKit

/// The model picker's pros and cons must never contradict the provider's facts.
@Suite("Provider descriptors")
struct ProviderDescriptorTests {

    static var shipped: [ProviderDescriptor] {
        let store = InMemoryCredentialStore()
        var list: [ProviderDescriptor] = [
            ChatCompletionsProvider.openAI(credentials: store).descriptor,
            ChatCompletionsProvider.openRouter(credentials: store).descriptor,
            ChatCompletionsProvider.vercelAIGateway(credentials: store).descriptor,
        ]
        #if canImport(FoundationModels)
        list.append(AppleOnDeviceProvider().descriptor)
        #endif
        return list
    }

    @Test("ids are persistable and unique")
    func ids() throws {
        let ids = Self.shipped.map(\.id)
        #expect(ids.allSatisfy { $0.isWellFormed })
        #expect(Set(ids).count == ids.count)
    }

    @Test("privacy claims follow from where inference runs", arguments: Self.shipped)
    func privacyIsDerived(_ descriptor: ProviderDescriptor) {
        let leaves = descriptor.tradeoffs.contains { if case .textLeavesDevice = $0 { true } else { false } }
        let stays = descriptor.tradeoffs.contains(.staysOnDevice)

        #expect(leaves != stays, "\(descriptor.displayName) must claim exactly one of the two")
        if case .remote(let recipients) = descriptor.traits.execution {
            #expect(!recipients.isEmpty, "a remote provider names who receives the text")
            #expect(descriptor.drawbacks.contains(.requiresNetwork))
        }
    }

    @Test("cost and credential claims follow from the traits", arguments: Self.shipped)
    func costIsDerived(_ descriptor: ProviderDescriptor) {
        #expect(descriptor.tradeoffs.contains(.free) == (descriptor.traits.cost == .free))
        #expect(descriptor.tradeoffs.contains(.paidPerUse) == (descriptor.traits.cost == .payPerUse))
        #expect(descriptor.tradeoffs.contains(.requiresAPIKey) == (descriptor.traits.credential == .apiKey))
    }

    @Test("every provider shows at least one advantage and one drawback", arguments: Self.shipped)
    func balanced(_ descriptor: ProviderDescriptor) {
        #expect(!descriptor.advantages.isEmpty)
        #expect(!descriptor.drawbacks.isEmpty)
    }

    @Test("aggregators name the party they route to, as typed recipients")
    func routedRecipients() {
        let store = InMemoryCredentialStore()
        func recipients(_ descriptor: ProviderDescriptor) -> [Recipient] {
            if case .remote(let recipients) = descriptor.traits.execution { return recipients }
            return []
        }
        #expect(recipients(ChatCompletionsProvider.openRouter(credentials: store).descriptor)
            == [.named("OpenRouter"), .routedInferenceProvider])
        #expect(recipients(ChatCompletionsProvider.vercelAIGateway(credentials: store).descriptor)
            == [.named("Vercel"), .modelServingProvider])
        #expect(recipients(ChatCompletionsProvider.openAI(credentials: store).descriptor) == [.named("OpenAI")])
        let lan = ChatCompletionsProvider.custom(
            id: "lan", displayName: "LAN", baseURL: URL(string: "https://models.example.local/v1")!,
            requiresAPIKey: true, credentials: store)
        #expect(recipients(lan.descriptor) == [.host("models.example.local")])
        // The picker's drawback carries the same typed recipients.
        #expect(ChatCompletionsProvider.openRouter(credentials: store).descriptor.drawbacks
            .contains(.textLeavesDevice(recipients: [.named("OpenRouter"), .routedInferenceProvider])))
    }

    @Test("OpenAI's preset says it offers one vendor's models")
    func singleVendor() {
        let store = InMemoryCredentialStore()
        #expect(ChatCompletionsProvider.openAI(credentials: store).descriptor.drawbacks.contains(.singleVendorCatalog))
        #expect(!ChatCompletionsProvider.openRouter(credentials: store).descriptor.tradeoffs.contains(.singleVendorCatalog))
    }

    @Test("a small context window is surfaced as a drawback")
    func smallContextIsDerived() {
        let small = ProviderTraits(execution: .onDevice, cost: .free, credential: .none, maxContextTokens: 4_096)
        let large = ProviderTraits(execution: .onDevice, cost: .free, credential: .none, maxContextTokens: 128_000)

        #expect(small.derivedTradeoffs.contains(.smallContext(tokens: 4_096)))
        #expect(!large.derivedTradeoffs.contains { if case .smallContext = $0 { true } else { false } })
    }

    @Test("a note that repeats a derived fact appears once")
    func noDuplicates() {
        let descriptor = ProviderDescriptor(
            id: "x", displayName: "X",
            traits: ProviderTraits(execution: .onDevice, cost: .free, credential: .none),
            notes: [.free, .smallModel])

        #expect(descriptor.tradeoffs.filter { $0 == .free }.count == 1)
    }
}

extension ProviderDescriptor: CustomTestStringConvertible {
    public var testDescription: String { displayName }
}
