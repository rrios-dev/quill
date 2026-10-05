import Foundation
import ModelKit
import RewriteKit

/// The menu's provider line (ARCHITECTURE §5.1): available, needs a key, Apple
/// Intelligence off, or needs a provider. Evaluated afresh every time the menu opens,
/// so a key removed in Settings shows on the next opening.
enum ProviderStatus: Equatable, Sendable {
    case available(provider: String)
    case needsKey(provider: String)
    case appleIntelligenceOff
    /// The Mac cannot run it, or the build lacks the framework.
    case notSupported(provider: String)
    /// The on-device model is downloading or preparing.
    case preparing(provider: String)
    /// No model resolves, or the stored one names a provider that no longer exists.
    case needsProvider

    /// The model the next rewrite would use when the menu cannot know the target app:
    /// the menu's next-rewrite profile, else the last used one; its pinned model, else
    /// the global choice (ARCHITECTURE §5.3).
    static func selection(settings: QuillSettings, profiles: [Profile]) -> ModelSelection? {
        let profileID = settings.nextRewriteProfile ?? settings.lastUsedProfile
        let profile = profileID.flatMap { id in profiles.first { $0.id == id } }
        return profile?.model ?? settings.globalModel
    }

    static func evaluate(_ selection: ModelSelection?, registry: ProviderRegistry) async -> ProviderStatus {
        guard let selection, let provider = registry[selection.provider] else { return .needsProvider }
        let name = provider.descriptor.displayName
        switch await provider.availability() {
        case .available: return .available(provider: name)
        case .unavailable(.missingCredential): return .needsKey(provider: name)
        case .unavailable(.appleIntelligenceDisabled): return .appleIntelligenceOff
        case .unavailable(.modelNotReady): return .preparing(provider: name)
        case .unavailable(.deviceNotEligible), .unavailable(.unsupportedPlatform): return .notSupported(provider: name)
        }
    }

    var title: String {
        switch self {
        case .available(let provider): String(localized: "menu.status.available \(provider)", bundle: .localized)
        case .needsKey(let provider): String(localized: "menu.status.needsKey \(provider)", bundle: .localized)
        case .appleIntelligenceOff: String(localized: "menu.status.appleIntelligenceOff", bundle: .localized)
        case .notSupported(let provider): String(localized: "menu.status.notSupported \(provider)", bundle: .localized)
        case .preparing(let provider): String(localized: "menu.status.preparing \(provider)", bundle: .localized)
        case .needsProvider: String(localized: "menu.status.needsProvider", bundle: .localized)
        }
    }
}
