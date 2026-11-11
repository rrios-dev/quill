import ModelKit

/// When a rewrite on the user's own plan fails because the plan cannot serve it — not
/// signed in, the tool missing, the plan's limit reached — Quill offers another model
/// the user can already use, and says which (quill J-23). It never switches on its own:
/// Return in the failure tries it, once.
enum PlanFallback {
    /// Failures a different provider can get past. A refusal or a malformed request
    /// would fail the same way elsewhere.
    static func applies(to code: ProviderError.Code) -> Bool {
        switch code {
        case .unavailable(.notSignedIn), .unavailable(.appNotInstalled), .unavailable(.planNotEligible), .rateLimited: true
        default: false
        }
    }

    /// The first available of: the global model, the recommended hosted models, the
    /// on-device one — never the provider that just failed.
    static func pick(failed: ModelSelection, code: ProviderError.Code, global: ModelSelection?,
                     registry: ProviderRegistry, recommended: [ProviderID: [ModelID]]) async -> ModelSelection? {
        guard applies(to: code), registry[failed.provider]?.descriptor.traits.cost == .includedInPlan else { return nil }
        var candidates: [ModelSelection] = global.map { [$0] } ?? []
        for provider in registry.providers where provider.id != failed.provider {
            for model in recommended[provider.id] ?? [] {
                candidates.append(ModelSelection(provider: provider.id, model: model))
            }
        }
        candidates.append(ModelSelection(provider: "apple.on-device", model: "system"))
        for candidate in candidates where candidate.provider != failed.provider {
            if await registry[candidate.provider]?.availability() == .available { return candidate }
        }
        return nil
    }
}
