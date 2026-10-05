import AppCore
import Foundation
import ModelKit
import Observation
import QuillSupport
import RewriteKit
import SelectionKit

/// First run (PRODUCT F4, U8). The steps, their order and the provider default live here;
/// the window only renders them.
@MainActor
@Observable
final class OnboardingModel {
    enum Step: String, CaseIterable, Equatable {
        case welcome, relocate, accessibility, clipboard, provider, shortcut, practice
    }

    /// The provider step's preselection (README Q5): the on-device model only when the
    /// bench says "works well" for every built-in on it; otherwise a hosted model is
    /// recommended, and Apple Intelligence is still offered with its label.
    enum ProviderDefault: Equatable {
        case onDevice
        case hosted
    }

    private(set) var steps: [Step] = []
    private(set) var current: Step = .welcome
    private(set) var permission: PermissionWatcher.State
    private(set) var clipboardAccess: PasteboardAccess
    private(set) var providerDefault: ProviderDefault = .hosted
    /// The readiness label of the on-device model, shown beside it.
    private(set) var onDeviceLabel: ReadinessLabel = .notEvaluated
    private(set) var onDeviceAvailability: ProviderAvailability = .unavailable(.unsupportedPlatform)
    let relocation: AppRelocation.Decision
    /// The Providers pane's model: keys, model lists and the hosted notice, reused as is.
    let providers: ProvidersPaneModel

    private let settings: SettingsStore
    private let profiles: ProfileStore
    private let registry: ProviderRegistryHolder
    private let readiness: ReadinessIndex
    private let composer: PromptComposer?
    private let isTrusted: () -> Bool
    private let readAccess: () -> PasteboardAccess
    private let onDeviceModel = ModelSelection(provider: AppleOnDeviceProvider.providerID, model: "system")
    private let log = QuillLog(category: "onboarding")

    init(settings: SettingsStore, profiles: ProfileStore, registry: ProviderRegistryHolder, readiness: ReadinessIndex,
         providers: ProvidersPaneModel, relocation: AppRelocation.Decision,
         isTrusted: @escaping () -> Bool, readAccess: @escaping () -> PasteboardAccess,
         composer: PromptComposer? = try? PromptComposer()) {
        self.settings = settings
        self.profiles = profiles
        self.registry = registry
        self.readiness = readiness
        self.providers = providers
        self.relocation = relocation
        self.isTrusted = isTrusted
        self.readAccess = readAccess
        self.composer = composer
        permission = isTrusted() ? .trusted : .notTrusted
        clipboardAccess = readAccess()
        steps = Self.steps(relocation: relocation, clipboardAccess: clipboardAccess)
    }

    /// Relocation only when there is something to offer; the clipboard step only where the
    /// policy is enforced (on macOS 26 Quill sees Always Allow, so it is skipped).
    static func steps(relocation: AppRelocation.Decision, clipboardAccess: PasteboardAccess) -> [Step] {
        Step.allCases.filter { step in
            switch step {
            case .relocate: relocation.isOffer
            case .clipboard: !clipboardAccess.allowsReading
            default: true
            }
        }
    }

    var isLast: Bool { current == steps.last }

    func next() {
        guard let index = steps.firstIndex(of: current), steps.indices.contains(index + 1) else { return }
        current = steps[index + 1]
    }

    func back() {
        guard let index = steps.firstIndex(of: current), index > 0 else { return }
        current = steps[index - 1]
    }

    // MARK: Accessibility

    /// Re-reads the grant; a grant that arrived while running asks for a restart.
    func refreshPermission() {
        permission = PermissionWatcher.next(permission, trusted: isTrusted())
    }

    // MARK: Clipboard

    /// After "Check clipboard access" made macOS ask and the user came back from System
    /// Settings: the behaviour is read again (ARCHITECTURE §3.4).
    func refreshClipboardAccess() {
        clipboardAccess = readAccess()
    }

    // MARK: Provider

    func evaluateProviders() async {
        if let provider = registry.current[onDeviceModel.provider] {
            onDeviceAvailability = await provider.availability()
        }
        onDeviceLabel = builtInLabel(on: onDeviceModel, contextTokens: registry.current[onDeviceModel.provider]?.descriptor.traits.maxContextTokens)
        providerDefault = Self.providerDefault(onDeviceAvailability: onDeviceAvailability, label: onDeviceLabel)
        await providers.refresh()
    }

    static func providerDefault(onDeviceAvailability: ProviderAvailability, label: ReadinessLabel) -> ProviderDefault {
        onDeviceAvailability.isAvailable && label == .worksWell ? .onDevice : .hosted
    }

    /// The weakest label among the built-ins on a model: "works well" only if all are.
    func builtInLabel(on model: ModelSelection, contextTokens: Int?) -> ReadinessLabel {
        guard let composer else { return .notEvaluated }
        let builtIns = ((try? profiles.all().profiles) ?? []).filter { $0.builtIn != nil }
        let shipped = builtIns.isEmpty ? ((try? BuiltInProfiles.all(language: "es")) ?? []) : builtIns
        let labels = shipped.map { readiness.label(for: $0, model: model, contextTokens: contextTokens, composer: composer) }
        let order: [ReadinessLabel] = [.notRecommended, .notEvaluated, .notEvaluatedEdited, .mayNeedReview, .worksWell]
        return labels.min { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! } ?? .notEvaluated
    }

    /// Chooses the on-device model as the global choice.
    func chooseOnDevice() {
        do {
            try settings.update { $0.globalModel = onDeviceModel }
        } catch {
            log.error("could not save the model: \(error)")
        }
    }

    /// "Turn on Apple Intelligence" is offered when it is off, downloading or unsupported
    /// and no hosted provider has a key.
    var offersAppleIntelligenceSettings: Bool {
        !onDeviceAvailability.isAvailable && !providers.rows.contains { $0.isRemote && $0.hasKey }
    }

    // MARK: Finish

    /// Done — or "Set up later", which finishes without a model: the menu bar then shows
    /// "Choose a model".
    func finish() {
        do {
            try settings.update { $0.onboardingCompleted = true }
        } catch {
            log.error("could not record the onboarding: \(error)")
        }
    }
}
