import AppKit
import ModelKit
import RewriteKit
import SelectionKit

/// SelectionKit's capture and replace sequences, for the session (ARCHITECTURE §3.1–3.2).
@MainActor
final class LiveSessionSelection: SessionSelection {
    private let operations: SelectionOperations
    private let capturer: SelectionCapturer
    private let replacer: SelectionReplacer
    /// The snapshot taken while the model generates; consumed by the next replace.
    private var snapshot: PasteboardSnapshotter.Outcome?
    /// Orders the picker out before ⌘V: a hidden panel keeps key status and swallows it.
    var orderOutPicker: @MainActor () -> Void = {}

    init(operations: SelectionOperations, settings: KillSwitches) {
        self.operations = operations
        capturer = SelectionCapturer(operations: operations, settings: CaptureSettings(
            copyFallbackEnabled: settings.copyFallback,
            manualAccessibilityEnabled: settings.manualAccessibility,
            enhancedAccessibilityEnabled: settings.enhancedAccessibility))
        replacer = SelectionReplacer(operations: operations)
    }

    static func live(settings: KillSwitches) -> LiveSessionSelection {
        LiveSessionSelection(
            operations: SelectionOperations(
                accessibility: LiveAccessibilityClient(), pasteboard: LivePasteboardClient(), keys: LiveKeyEventPoster()),
            settings: settings)
    }

    func processTerminated(_ pid: pid_t) { capturer.processTerminated(pid) }

    func capture(app: AppIdentity, hotKeyCode: CGKeyCode?) async -> Result<Capture, CaptureRefusal> {
        snapshot = nil
        let height = NSScreen.screens.first?.frame.height ?? 0
        return await capturer.capture(app: app, hotKeyCode: hotKeyCode, primaryScreenHeight: height, clock: ContinuousClock())
    }

    func prepareSnapshot() async {
        snapshot = await replacer.takeSnapshot()
    }

    func replace(_ text: String, capture: Capture, pasteAnyway: Bool) async -> ReplaceOutcome {
        let orderOut = orderOutPicker
        let outcome = await replacer.replace(
            text, capture: capture, pasteAnyway: pasteAnyway, snapshot: snapshot,
            orderOut: { await MainActor.run { orderOut() } }, clock: ContinuousClock())
        if outcome != .clipboardBusy { snapshot = nil }
        return outcome
    }

    func copy(_ text: String) async -> Bool {
        await replacer.copyResult(text, snapshot: snapshot)
    }

    func clipboardReadFinished() async {
        guard let read = snapshot?.pendingRead else { return }
        let finished = await read.finished()
        snapshot = PasteboardSnapshotter.Outcome(snapshot: finished, pendingRead: nil)
    }

    func strategy(for bundleIdentifier: String?) -> AppStrategy {
        AppStrategy.strategy(for: bundleIdentifier)
    }
}

/// Context sizes, prices and too-long alternatives. The on-device model answers from
/// the framework; hosted models from the Providers pane's cached lists.
final class LiveModelCatalog: ModelCatalog, @unchecked Sendable {
    private let registry: ProviderRegistryHolder
    private let listCache: ModelListCache?
    private let lock = NSLock()
    private var cache: [ProviderID: [ModelDescriptor]] = [:]

    init(registry: ProviderRegistryHolder, listCache: ModelListCache? = nil) {
        self.registry = registry
        self.listCache = listCache
    }

    /// The on-device model from the framework; a hosted one from the Providers pane's
    /// cached list (never fetched here: a rewrite makes no listing call).
    func descriptor(for selection: ModelSelection) async -> ModelDescriptor? {
        if let found = await models(of: selection.provider).first(where: { $0.id == selection.model }) { return found }
        return listCache?.cached(selection.provider)?.models.map(\.descriptor).first { $0.id == selection.model }
    }

    func alternatives() async -> [ModelCandidate] {
        var candidates: [ModelCandidate] = []
        for provider in registry.current.providers where provider.descriptor.traits.execution == .onDevice {
            for model in await models(of: provider.id) {
                guard let context = model.contextTokens ?? provider.descriptor.traits.maxContextTokens else { continue }
                candidates.append(ModelCandidate(selection: ModelSelection(provider: provider.id, model: model.id),
                                                 contextTokens: context, runsOnDevice: true))
            }
        }
        return candidates
    }

    /// Only the on-device provider is asked: listing a server's models is a network
    /// call, made only by the Providers pane (ARCHITECTURE §6).
    private func models(of id: ProviderID) async -> [ModelDescriptor] {
        if let cached = lock.withLock({ cache[id] }) { return cached }
        guard let provider = registry.current[id], provider is AppleOnDeviceProvider else { return [] }
        let models = (try? await provider.models()) ?? []
        lock.withLock { cache[id] = models }
        return models
    }
}

/// "Save as example" into the profile store. The editor side (PLAN P4-T4) adds the
/// review of stand-ins before they are saved.
@MainActor
final class StoreExampleSink: ExampleSink {
    private let profiles: ProfileStore

    init(profiles: ProfileStore) { self.profiles = profiles }

    func save(_ example: Example, to profileID: UUID, replacing: UUID?) throws -> Profile {
        guard var profile = try profiles.profile(profileID) else { throw ProfileStoreError.notFound(profileID) }
        if let replacing { profile.examples.removeAll { $0.id == replacing } }
        profile.examples.append(example)
        return try profiles.save(profile)
    }

    func neutralized(_ example: Example) -> Example {
        Example(id: example.id, input: PersonalDataScreen.withStandIns(example.input),
                output: PersonalDataScreen.withStandIns(example.output), addedAt: example.addedAt)
    }
}
