import Foundation
import ModelKit
import Observation
import QuillSupport
import RewriteKit

/// Settings → Profiles (PRODUCT F3, U6): the editor, versions, Try it, export and
/// import, restoring the built-ins. The view only renders this; the rules live here.
@MainActor
@Observable
final class ProfilesPaneModel {
    /// What the composer would send of the draft to its model (ARCHITECTURE §4.3–4.4).
    struct Marks: Equatable {
        /// Compact strategy: only the first N words of guidance travel.
        var guidanceSentWords: Int?
        var guidanceSkippedForPersonalData = false
        var notSentForBudget: Set<UUID> = []
        var notSentForPersonalData: Set<UUID> = []
    }

    /// One sample's run: the text and its signals (PRODUCT F3 item 2).
    struct TryItResult: Equatable {
        var sampleID: UUID
        var text: String?
        var flags: [GuardFlag] = []
        var noChanges = false
        var failure: SessionState?
        /// Output words / input words.
        var lengthRatio: Double?
    }

    enum TryItOutcome: Equatable {
        case ran
        case needsConsent(ConsentNotice)
        case noModel
    }

    private(set) var profiles: [Profile] = []
    private(set) var selectedID: UUID?
    /// The profile being edited; saved as a new version by `save()`.
    var draft: Profile?
    private(set) var versions: [Profile] = []
    private(set) var samples = SampleSet()
    private(set) var tryItResults: [UUID: TryItResult] = [:]
    private(set) var marks = Marks()
    private(set) var problem: ProfileError?
    /// The notice Try it is waiting on.
    private(set) var pendingConsent: ConsentNotice?

    private let settings: SettingsStore
    private let store: ProfileStore
    private let registry: ProviderRegistryHolder
    private let catalog: any ModelCatalog
    private let engine: GenerationEngine?
    private let composer: PromptComposer?
    private let readinessIndex: ReadinessIndex
    private let treatLoopbackAsRemote: Bool
    private let language: String
    private let log = QuillLog(category: "profiles")

    init(settings: SettingsStore, profiles: ProfileStore, registry: ProviderRegistryHolder, catalog: any ModelCatalog,
         readiness: ReadinessIndex, engine: GenerationEngine? = try? GenerationEngine(),
         composer: PromptComposer? = try? PromptComposer(), treatLoopbackAsRemote: Bool = false,
         language: String = AppEnvironment.profileLanguage()) {
        self.settings = settings
        self.store = profiles
        self.registry = registry
        self.catalog = catalog
        self.engine = engine
        self.composer = composer
        self.readinessIndex = readiness
        self.treatLoopbackAsRemote = treatLoopbackAsRemote
        self.language = language
    }

    // MARK: List and selection

    func reload() async {
        profiles = ((try? store.all().profiles) ?? []).sorted(by: AppDelegate.menuOrder)
        if let selectedID, profiles.contains(where: { $0.id == selectedID }) {
            await select(selectedID)
        } else if let first = profiles.first {
            await select(first.id)
        } else {
            selectedID = nil
            draft = nil
        }
    }

    func select(_ id: UUID) async {
        selectedID = id
        draft = (try? store.profile(id)) ?? nil
        versions = ((try? store.versions(of: id)) ?? []).reversed()
        samples = (try? store.samples(of: id)) ?? SampleSet()
        tryItResults = [:]
        problem = nil
        await updateMarks()
    }

    /// A new profile, from scratch.
    func create(name: String) async {
        do {
            let profile = try store.save(Profile(name: name, symbol: "text.badge.star", settings: ProfileSettings(scope: .rewrite)))
            selectedID = profile.id
            await reload()
        } catch let error as ProfileError {
            problem = error
        } catch {
            log.error("could not create a profile: \(error)")
        }
    }

    /// Deletes a profile and every reference to it (its app mappings among them).
    func delete(_ id: UUID) async {
        do {
            try store.delete(id)
            try settings.update { $0.forgetProfile(id) }
        } catch {
            log.error("could not delete the profile: \(error)")
        }
        if selectedID == id { selectedID = nil }
        await reload()
    }

    // MARK: Editing

    var hasChanges: Bool {
        guard let draft, let stored = profiles.first(where: { $0.id == draft.id }) else { return false }
        var comparable = draft
        comparable.version = stored.version
        comparable.updatedAt = stored.updatedAt
        return comparable != stored
    }

    /// Saves the draft as a new version (validated; an invalid draft is not saved).
    func save() async {
        guard let draft else { return }
        do {
            try draft.validate()
            let saved = try store.save(draft)
            selectedID = saved.id
            await reload()
        } catch let error as ProfileError {
            problem = error
        } catch {
            log.error("could not save the profile: \(error)")
        }
    }

    func revert(to version: Int) async {
        guard let id = selectedID else { return }
        do {
            _ = try store.revert(id, to: version)
            await reload()
        } catch {
            log.error("could not revert: \(error)")
        }
    }

    /// What differs between a stored version and the current profile, field by field.
    func differences(from version: Profile) -> [String] {
        guard let current = profiles.first(where: { $0.id == version.id }) else { return [] }
        var fields: [String] = []
        if current.name != version.name { fields.append("name") }
        if current.settings != version.settings { fields.append("settings") }
        if current.guidance != version.guidance { fields.append("guidance") }
        if current.examples != version.examples { fields.append("examples") }
        if current.model != version.model { fields.append("model") }
        if current.temperature != version.temperature { fields.append("temperature") }
        return fields
    }

    // MARK: Examples

    func addExample(input: String, output: String) async {
        guard var draft else { return }
        draft.examples.append(Example(input: input, output: output))
        do {
            try draft.validate()
            self.draft = draft
            problem = nil
        } catch {
            problem = error
        }
        await updateMarks()
    }

    /// Deletes an example from the profile **and every stored version** (ARCHITECTURE §4.3).
    func deleteExample(_ id: UUID) async {
        guard let profileID = selectedID else { return }
        do {
            _ = try store.deleteExample(id, from: profileID)
            await reload()
        } catch {
            log.error("could not delete the example: \(error)")
        }
    }

    /// The identifier screen's findings for one example (the editor offers stand-ins).
    func findings(_ example: Example) -> Set<PersonalDataScreen.Kind> {
        PersonalDataScreen.findings(in: example.input).union(PersonalDataScreen.findings(in: example.output))
    }

    func standIns(for example: Example) async {
        guard var draft, let index = draft.examples.firstIndex(where: { $0.id == example.id }) else { return }
        draft.examples[index].input = PersonalDataScreen.withStandIns(example.input)
        draft.examples[index].output = PersonalDataScreen.withStandIns(example.output)
        self.draft = draft
        await updateMarks()
    }

    /// Recomputes the "not sent" marks for the draft on its model.
    func updateMarks() async {
        guard let draft, let composer, let model = resolvedModel(for: draft) else {
            marks = Marks()
            return
        }
        let context = await contextTokens(for: model)
        let provider = registry.current[model.provider]
        let prompt = await composer.compose(
            profile: draft, input: "", model: model.model, contextTokens: context,
            estimate: { text in
                guard let provider else { return Int((Double(text.count) / TokenEstimate.charactersPerToken).rounded(.up)) }
                return await provider.estimateTokens(GenerationRequest(model: model.model, instructions: "", input: text))
            })
        var marks = Marks()
        switch prompt.report.guidance {
        case .truncated(let words): marks.guidanceSentWords = words
        case .skippedForPersonalData: marks.guidanceSkippedForPersonalData = true
        case .none, .sent: break
        }
        marks.notSentForBudget = Set(prompt.report.droppedForBudget)
        marks.notSentForPersonalData = Set(prompt.report.skippedForPersonalData)
        self.marks = marks
    }

    // MARK: Samples and Try it

    func addSample(_ text: String) {
        guard let id = selectedID else { return }
        var updated = samples
        updated.samples.append(Sample(text: text))
        do {
            try store.saveSamples(updated, for: id)
            samples = updated
        } catch let error as ProfileError {
            problem = error
        } catch {
            log.error("could not save the sample: \(error)")
        }
    }

    func removeSample(_ id: UUID) {
        guard let profileID = selectedID else { return }
        var updated = samples
        updated.samples.removeAll { $0.id == id }
        try? store.saveSamples(updated, for: profileID)
        samples = updated
        tryItResults[id] = nil
    }

    /// Runs the saved profile on every sample with its model. Samples are user text: a
    /// hosted recipient goes through the same consent as a rewrite first.
    @discardableResult
    func tryIt(confirmed: Bool = false) async -> TryItOutcome {
        guard let id = selectedID, let profile = try? store.profile(id), let engine else { return .noModel }
        guard let model = resolvedModel(for: profile), let provider = registry.current[model.provider] else { return .noModel }
        let remote = ConsentRule.isRemote(provider.descriptor, treatLoopbackAsRemote: treatLoopbackAsRemote)
        if !confirmed, !samples.samples.isEmpty,
           let notice = ConsentRule.notice(for: provider.descriptor, profile: profile,
                                           settings: (try? settings.settings()) ?? QuillSettings(), remote: remote) {
            pendingConsent = notice
            return .needsConsent(notice)
        }
        let context = await contextTokens(for: model)
        var updated = samples
        for index in updated.samples.indices {
            let sample = updated.samples[index]
            let request = GenerationEngine.Request(
                profile: profile, input: sample.text, model: model, contextTokens: context, runsOnDevice: !remote,
                formatting: .plain, streams: false)
            let outcome = await engine.run(request, provider: provider)
            var result = TryItResult(sampleID: sample.id)
            switch outcome.state {
            case .ready(let text, let flags):
                result.text = text
                result.flags = flags
                result.lengthRatio = Self.ratio(sample.text, text)
                if sample.currentResult?.profileVersion != profile.version {
                    updated.samples[index].previousResult = sample.currentResult
                }
                updated.samples[index].currentResult = SampleResult(profileVersion: profile.version, model: model, text: text)
            case .noChanges:
                result.noChanges = true
            case .truncated(let partial):
                result.failure = .truncated(partial: partial)
            case .refused:
                result.failure = .refused
            case .tooLong(let suggestion):
                result.failure = .tooLong(model: model, suggestion: suggestion)
            case .failed(let code, let partial):
                result.failure = .failed(.provider(code), partial: partial)
            case .idle, .generating, .cancelled:
                break
            }
            tryItResults[sample.id] = result
        }
        try? store.saveSamples(updated, for: id)
        samples = updated
        return .ran
    }

    func acceptTryItConsent() async {
        guard let notice = pendingConsent, let id = selectedID else { return }
        pendingConsent = nil
        do {
            try ConsentRule.record(notice, profileID: id, in: settings)
        } catch {
            log.error("could not record the consent: \(error)")
            return
        }
        await tryIt(confirmed: true)
    }

    func declineTryItConsent() { pendingConsent = nil }

    static func ratio(_ input: String, _ output: String) -> Double? {
        let inputWords = RewriteSession.wordCount(input)
        guard inputWords > 0 else { return nil }
        return Double(RewriteSession.wordCount(output)) / Double(inputWords)
    }

    // MARK: Export, import, built-ins

    /// A `.quillprofile` file. The view warns first: it holds the profile's examples and,
    /// when included, its samples — user text (PRODUCT F3 item 5).
    func export(includeSamples: Bool) throws -> Data? {
        guard let id = selectedID else { return nil }
        return try store.export(id, includeSamples: includeSamples)
    }

    func importProfile(_ data: Data) async throws {
        let imported = try store.importProfile(data)
        selectedID = imported.id
        await reload()
    }

    /// Brings back the built-ins the user deleted, leaving every other profile alone.
    @discardableResult
    func restoreBuiltIns() async -> Int {
        let restored = (try? store.restoreBuiltIns(language: language)) ?? []
        await reload()
        return restored.count
    }

    // MARK: Model and readiness

    /// The model a profile runs on: its pinned one — which never falls back to another
    /// (README D-16) — or the global one.
    func resolvedModel(for profile: Profile) -> ModelSelection? {
        profile.model ?? ((try? settings.settings()) ?? QuillSettings()).globalModel
    }

    private func contextTokens(for model: ModelSelection) async -> Int? {
        if let context = registry.current[model.provider]?.descriptor.traits.maxContextTokens { return context }
        return await catalog.descriptor(for: model)?.contextTokens
    }

    /// The draft's readiness on its model: an edited built-in reads "not evaluated (edited)".
    func readiness() async -> ReadinessLabel {
        guard let draft, let composer, let model = resolvedModel(for: draft) else { return .notEvaluated }
        return readinessIndex.label(for: draft, model: model, contextTokens: await contextTokens(for: model), composer: composer)
    }
}
