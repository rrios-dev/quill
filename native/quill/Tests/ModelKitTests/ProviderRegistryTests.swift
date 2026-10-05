import Foundation
import Testing

@testable import ModelKit

@Suite("Provider registry")
struct ProviderRegistryTests {

    private let store = InMemoryCredentialStore(["openrouter": "sk"])

    @Test("two providers with the same id are rejected at launch, not at first use")
    func duplicateID() {
        #expect(throws: RegistryError.duplicateID("openrouter")) {
            try ProviderRegistry([
                ChatCompletionsProvider.openRouter(credentials: store),
                ChatCompletionsProvider.openRouter(credentials: store),
            ])
        }
    }

    @Test("an id that could not be persisted safely is rejected")
    func malformedID() {
        let bad = ChatCompletionsProvider.custom(id: "My Server", displayName: "x", baseURL: URL(string: "https://x.example/v1")!,
                                                 requiresAPIKey: false, credentials: store)
        #expect(throws: RegistryError.malformedID("My Server")) { try ProviderRegistry([bad]) }
    }

    @Test("a stored selection resolves to its provider and runs through it")
    func resolvesSelection() async throws {
        let registry = try ProviderRegistry([
            ChatCompletionsProvider.openRouter(credentials: store, transport: ScriptedTransport(.lines(sseStream("Hola")))),
        ])
        let stream = try registry.stream(ModelSelection(provider: "openrouter", model: "m"), instructions: "i", input: "hola")
        let outcome = await collect(stream)

        #expect(outcome.result?.text == "Hola")
    }

    @Test("a selection naming a provider that no longer exists fails with a contract error")
    func unknownProvider() throws {
        let registry = try ProviderRegistry([])
        #expect(throws: ProviderError.self) {
            try registry.provider(for: ModelSelection(provider: "gone", model: "m"))
        }
    }
}
