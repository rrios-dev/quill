import Foundation
import ModelKit
import Testing

@testable import Quill

/// J-23: when the user's own plan cannot serve a rewrite, Quill names another model the
/// user can use and tries it only on Return, once.
@Suite("Plan fallback")
struct PlanFallbackTests {
    /// A provider with fixed traits and availability, for picking only.
    struct Stub: ModelProvider {
        let descriptor: ProviderDescriptor
        let available: Bool

        init(_ id: ProviderID, cost: ProviderTraits.Cost, available: Bool = true) {
            descriptor = ProviderDescriptor(id: id, displayName: id.rawValue,
                                            traits: ProviderTraits(execution: .remote(recipients: [.named("X")]), cost: cost,
                                                                   credential: .none))
            self.available = available
        }

        func availability() async -> ProviderAvailability { available ? .available : .unavailable(.notSignedIn) }
        func models() async throws -> [ModelDescriptor] { [] }
        func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    static let failed = ModelSelection(provider: "claude-code", model: "sonnet")
    static let recommended: [ProviderID: [ModelID]] = ["openrouter": ["google/gemini-3.8-flash"]]

    private func registry(openRouter: Bool = true, onDevice: Bool = true) throws -> ProviderRegistry {
        try ProviderRegistry([
            Stub("claude-code", cost: .includedInPlan),
            Stub("openrouter", cost: .payPerUse, available: openRouter),
            Stub("apple.on-device", cost: .free, available: onDevice),
        ])
    }

    @Test("a plan that cannot serve offers the global model when it is elsewhere")
    func global() async throws {
        let global = ModelSelection(provider: "openrouter", model: "openai/gpt-6-luna")
        let pick = await PlanFallback.pick(failed: Self.failed, code: .rateLimited(retryAfter: nil), global: global,
                                           registry: try registry(), recommended: Self.recommended)
        #expect(pick == global)
    }

    @Test("with the plan as the global model, the next available recommended model, then the Mac's")
    func order() async throws {
        let afterPlan = await PlanFallback.pick(failed: Self.failed, code: .unavailable(.notSignedIn), global: Self.failed,
                                                registry: try registry(), recommended: Self.recommended)
        #expect(afterPlan == ModelSelection(provider: "openrouter", model: "google/gemini-3.8-flash"))

        let noKey = await PlanFallback.pick(failed: Self.failed, code: .unavailable(.appNotInstalled), global: nil,
                                            registry: try registry(openRouter: false), recommended: Self.recommended)
        #expect(noKey == ModelSelection(provider: "apple.on-device", model: "system"))

        let nothing = await PlanFallback.pick(failed: Self.failed, code: .unavailable(.notSignedIn), global: nil,
                                              registry: try registry(openRouter: false, onDevice: false), recommended: Self.recommended)
        #expect(nothing == nil)
    }

    @Test("other failures, and failures off a plan, offer nothing")
    func onlyPlanFailures() async throws {
        let refused = await PlanFallback.pick(failed: Self.failed, code: .refused, global: nil,
                                              registry: try registry(), recommended: Self.recommended)
        #expect(refused == nil, "a refusal would repeat elsewhere")

        let paid = await PlanFallback.pick(failed: ModelSelection(provider: "openrouter", model: "m"),
                                           code: .rateLimited(retryAfter: nil), global: nil,
                                           registry: try registry(), recommended: Self.recommended)
        #expect(paid == nil, "only the user's own plans fall back")
    }
}
