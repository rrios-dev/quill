import CoreGraphics
import Foundation
import ModelKit
import Observation
import os
import QuillSupport
import RewriteKit
import SelectionKit

/// One rewrite, from the shortcut to the applied result: the picker's view model
/// (ARCHITECTURE §2, §5.2; PRODUCT §4.1). The view only renders `state` and forwards
/// keys; every rule of the table lives here, where a test reaches it.
@MainActor
@Observable
final class RewriteSession {
    /// Over this many words a hosted rewrite waits for Return (ARCHITECTURE §5.3).
    static let largeTextWords = 1_500

    // MARK: Dependencies

    private let settings: SettingsStore
    private let profiles: ProfileStore
    private let registryHolder: ProviderRegistryHolder
    private let engine: GenerationEngine
    private let guards: OutputGuards
    private let selection: any SessionSelection
    private let catalog: any ModelCatalog
    private let examples: any ExampleSink
    /// `QUILL_TREAT_LOOPBACK_AS_REMOTE`: a loopback server goes through the hosted paths
    /// (consent, waiting to start, cost), so the mock server exercises them.
    private let treatLoopbackAsRemote: Bool
    private let log = QuillLog(category: "session")

    /// Effects the window performs: show or close the picker, a toast, open Settings.
    var onEffect: (SessionEffect) -> Void = { _ in }

    // MARK: What the picker shows

    private(set) var state: SessionState = .idle
    private(set) var profile: Profile?
    /// The profiles 1–9 select, in the menu's order.
    private(set) var profileList: [Profile] = []
    private(set) var model: ModelSelection?
    private(set) var capture: Capture?
    /// D toggles it in Ready and Flagged.
    private(set) var showsDiff = false
    /// The app default named a profile that no longer exists (ARCHITECTURE §5.3).
    private(set) var staleAppDefault = false
    /// Why a direct apply opened the picker instead.
    private(set) var directApplyDeclined: DirectApplyDeclined?
    /// Whether this session started as a direct apply and the picker is not shown.
    private(set) var isDirectApply = false
    /// What the user is typing in the picker's instruction field (PRODUCT §4.1).
    var instructionDraft = ""
    /// The instruction the current result was made with; nil when a profile made it.
    private(set) var activeInstruction: String?

    /// The draft says something the current result was not made with: Return sends it.
    var instructionPending: Bool {
        let draft = instructionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !draft.isEmpty && draft != activeInstruction
    }

    /// The resolved model's provider, as the picker names it.
    var providerName: String? { model.flatMap { registry[$0.provider]?.descriptor.displayName } }
    private var pickerShown = false
    /// The result was applied without the picker (the toast then names the profile).
    private var appliedDirectly = false

    /// The ARCHITECTURE §11 intervals of this session, in milliseconds (also signposted).
    struct Timings: Equatable {
        var captureToPicker: Double?
        var firstToken: Double?
        var replace: Double?
    }

    private(set) var timings = Timings()
    private var startedAt: ContinuousClock.Instant?
    private var generationStartedAt: ContinuousClock.Instant?
    private var captureInterval: OSSignpostIntervalState?
    private var firstTokenInterval: OSSignpostIntervalState?

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }

    // MARK: Internals

    private var origin: Origin = .hotKey
    private var generationTask: Task<Void, Never>?
    /// Each generation's number; updates from an older one are ignored.
    private var generationNumber = 0
    /// The too-long suggestion is offered once (PRODUCT §4.1: "rerun once").
    private var usedSuggestion = false
    /// The registry the session started with: a rewrite in flight keeps it.
    private var registry: ProviderRegistry

    private enum Origin { case hotKey, services }

    init(settings: SettingsStore, profiles: ProfileStore, registry: ProviderRegistryHolder,
         engine: GenerationEngine, guards: OutputGuards, selection: any SessionSelection,
         catalog: any ModelCatalog, examples: any ExampleSink, treatLoopbackAsRemote: Bool = false) {
        self.settings = settings
        self.profiles = profiles
        self.registryHolder = registry
        self.registry = registry.current
        self.engine = engine
        self.guards = guards
        self.selection = selection
        self.catalog = catalog
        self.examples = examples
        self.treatLoopbackAsRemote = treatLoopbackAsRemote
    }

    // MARK: Start

    /// Starts a session. Returns once the capture is done and the generation (if any)
    /// has begun; `settle()` waits for the generation to end.
    func start(_ trigger: Trigger) async {
        registry = registryHolder.current
        timings = Timings()
        startedAt = .now
        captureInterval = QuillSignposts.signposter.beginInterval(QuillSignposts.capture)
        pickerShown = false
        appliedDirectly = false
        directApplyDeclined = nil
        usedSuggestion = false
        instructionDraft = ""
        activeInstruction = nil
        state = .capturing
        let current = (try? settings.settings()) ?? QuillSettings()
        profileList = ((try? profiles.all().profiles) ?? []).sorted(by: AppDelegate.menuOrder)

        let app: AppIdentity
        let hotKeyCode: CGKeyCode?
        switch trigger {
        case .hotKey(let identity, let code):
            app = identity
            hotKeyCode = code
            origin = .hotKey
        case .services(let delivered):
            app = delivered.app
            hotKeyCode = nil
            origin = .services
        }

        let resolved = resolveProfile(settings: current, bundleIdentifier: app.bundleIdentifier)
        profile = resolved
        model = resolved.flatMap { $0.model ?? current.globalModel }
        if current.nextRewriteProfile != nil {
            // The menu's choice is used once.
            _ = try? settings.update { $0.nextRewriteProfile = nil }
        }

        // Direct apply only when the app's default has it on, and never from Services.
        isDirectApply = origin == .hotKey && !staleAppDefault
            && app.bundleIdentifier.map { current.directApplyApps.contains($0) && current.appDefaults[$0] != nil } == true

        // Prewarm while the capture runs: the shortcut is the moment the user commits.
        if origin == .hotKey, let model, let provider = registry[model.provider] {
            let request = GenerationRequest(model: model.model, instructions: "", input: "")
            Task.detached { await provider.prewarm(for: request) }
        }

        switch trigger {
        case .hotKey:
            switch await selection.capture(app: app, hotKeyCode: hotKeyCode) {
            case .success(let captured): capture = captured
            case .failure(let refusal):
                state = .refusedCapture(refusal)
                presentPicker()
                return
            }
        case .services(let delivered):
            capture = delivered
        }
        if !isDirectApply { presentPicker() }
        await begin()
    }

    /// A capture refused before the session could start — the Services entry reads the
    /// focused element itself (a password field, for one).
    func showRefusal(_ refusal: CaptureRefusal) {
        pickerShown = false
        state = .refusedCapture(refusal)
        presentPicker()
    }

    #if DEBUG
    /// Puts the session in a state without running it, for `QUILL_DUMP_A11Y` to measure the
    /// picker in that state (debug builds only).
    func debugPresent(_ state: SessionState, capture: Capture?) {
        profileList = ((try? profiles.all().profiles) ?? []).sorted(by: AppDelegate.menuOrder)
        profile = profileList.first
        self.capture = capture
        self.state = state
        showsDiff = profile?.settings.scope == .spellingOnly
    }
    #endif

    /// Waits for the current generation to reach a terminal state.
    func settle() async {
        await generationTask?.value
    }

    /// The order of ARCHITECTURE §5.3: the menu's next-rewrite choice (once) › the app
    /// default › the last used. A stale app default falls back to the last used, with a
    /// note.
    private func resolveProfile(settings: QuillSettings, bundleIdentifier: String?) -> Profile? {
        staleAppDefault = false
        func find(_ id: UUID?) -> Profile? { id.flatMap { id in profileList.first { $0.id == id } } }
        if let next = find(settings.nextRewriteProfile) { return next }
        if let bundleIdentifier, let mapped = settings.appDefaults[bundleIdentifier] {
            if let profile = find(mapped) { return profile }
            staleAppDefault = true
        }
        return find(settings.lastUsedProfile) ?? profileList.first
    }

    // MARK: Gates before sending

    /// Checks what must happen before anything is sent: a model, consent, the Return a
    /// large hosted text or Services needs. Starts the generation when nothing does.
    private func begin(confirmed: Bool = false) async {
        guard let profile else { return fail(.chooseModel(profile: "")) }
        guard let model, let provider = registry[model.provider] else {
            return fail(.chooseModel(profile: profile.name))
        }
        // A pinned model whose provider cannot be used is never replaced by another.
        if profile.model != nil, case .unavailable = await provider.availability() {
            return fail(.chooseModel(profile: profile.name))
        }

        if !confirmed, let capture {
            let remote = isRemote(provider.descriptor)
            let large = remote && Self.wordCount(capture.text) > Self.largeTextWords
            let startNotice: StartNotice? = if large {
                StartNotice(reason: .largeText, words: Self.wordCount(capture.text),
                            estimatedCost: await estimatedCost(of: capture.text, model: model, provider: provider))
            } else if remote && origin == .services {
                StartNotice(reason: .services, words: Self.wordCount(capture.text),
                            estimatedCost: await estimatedCost(of: capture.text, model: model, provider: provider))
            } else {
                nil
            }
            if remote, let notice = consentNotice(for: provider.descriptor, profile: profile, startNotice: startNotice) {
                state = .awaitingConsent(notice)
                presentPicker()
                return
            }
            if let startNotice {
                state = .waitingToStart(startNotice)
                presentPicker()
                return
            }
        }
        await generate()
    }

    private func consentNotice(for descriptor: ProviderDescriptor, profile: Profile,
                               startNotice: StartNotice?) -> ConsentNotice? {
        ConsentRule.notice(for: descriptor, profile: profile, settings: (try? settings.settings()) ?? QuillSettings(),
                           remote: true, largeText: startNotice?.reason == .largeText ? startNotice : nil)
    }

    private func acceptConsent(_ notice: ConsentNotice) async {
        guard let profile else { return }
        do {
            try ConsentRule.record(notice, profileID: profile.id, in: settings)
        } catch {
            log.error("could not record the consent: \(error)")
            return
        }
        // Consent and the large-text confirmation are one step.
        await begin(confirmed: true)
    }

    private func isRemote(_ descriptor: ProviderDescriptor) -> Bool {
        ConsentRule.isRemote(descriptor, treatLoopbackAsRemote: treatLoopbackAsRemote)
    }

    private func estimatedCost(of text: String, model: ModelSelection, provider: any ModelProvider) async -> Double? {
        guard let pricing = await catalog.descriptor(for: model)?.pricing else { return nil }
        let tokens = await provider.estimateTokens(GenerationRequest(model: model.model, instructions: "", input: text))
        let usage = TokenUsage(inputTokens: tokens, outputTokens: Int((Double(tokens) * GenerationEngine.outputReserve).rounded(.up)))
        return pricing.cost(of: usage)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    // MARK: Generation

    private func generate() async {
        guard let profile, let model, let capture, let provider = registry[model.provider] else { return }
        generationTask?.cancel()
        generationNumber += 1
        let number = generationNumber
        // Corrections read best as marked changes; a rewrite reads best as the new text.
        showsDiff = profile.settings.scope == .spellingOnly && activeInstruction == nil
        state = .generating(partial: "")
        generationStartedAt = .now
        timings.firstToken = nil
        firstTokenInterval = QuillSignposts.signposter.beginInterval(QuillSignposts.firstToken)
        if capture.editability != .readOnlyOnly {
            Task { await selection.prepareSnapshot() }
        }

        let descriptor = await catalog.descriptor(for: model)
        let request = GenerationEngine.Request(
            profile: profile, input: capture.text, model: model,
            contextTokens: provider.descriptor.traits.maxContextTokens ?? descriptor?.contextTokens,
            runsOnDevice: !isRemote(provider.descriptor),
            formatting: Self.formatting(capture.formatting),
            alternatives: await catalog.alternatives(),
            instruction: activeInstruction)
        let engine = engine
        // Partial text crosses from the engine's context to the main actor in order.
        let (partials, sink) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        generationTask = Task { [weak self] in
            async let outcome = engine.run(request, provider: provider) { update in
                if case .generating(let partial) = update { sink.yield(partial) }
                if update.isTerminal { sink.finish() }
            }
            for await partial in partials {
                self?.showPartial(partial, generation: number)
            }
            let final = await outcome
            self?.finish(final.state, generation: number, model: model)
        }
    }

    private func showPartial(_ partial: String, generation: Int) {
        guard generation == generationNumber, case .generating(let shown) = state, partial.count >= shown.count else { return }
        if timings.firstToken == nil, !partial.isEmpty, let generationStartedAt {
            timings.firstToken = Self.milliseconds(since: generationStartedAt)
            if let firstTokenInterval { QuillSignposts.signposter.endInterval(QuillSignposts.firstToken, firstTokenInterval) }
        }
        state = .generating(partial: partial)
    }

    private func finish(_ outcome: GenerationState, generation: Int, model: ModelSelection) {
        guard generation == generationNumber else { return }
        switch outcome {
        case .idle, .generating:
            return
        case .cancelled:
            return
        case .ready(let text, let flags):
            state = flags.isEmpty ? .ready(text: text) : .flagged(text: text, flags: flags)
        case .noChanges:
            state = .noChanges
        case .truncated(let partial):
            state = .truncated(partial: partial)
        case .refused:
            state = .refused
        case .tooLong(let suggestion):
            state = .tooLong(model: model, suggestion: usedSuggestion ? nil : suggestion)
        case .failed(let code, let partial):
            state = .failed(.provider(code), partial: partial)
        }
        // A one-off instruction is not a profile: the next rewrite starts from the last one.
        if let profile, activeInstruction == nil { _ = try? settings.update { $0.lastUsedProfile = profile.id } }
        if isDirectApply { Task { await directApply() } }
    }

    /// PRODUCT F2, the single definition: a Ready result with no flag, an editable
    /// target, and an app whose strategy pastes with ⌘Z verified. Anything else opens
    /// the picker with the reason.
    private func directApply() async {
        isDirectApply = false
        guard let capture else { return }
        let strategy = selection.strategy(for: capture.app.bundleIdentifier)
        let declined: DirectApplyDeclined? = switch state {
        case .ready:
            if capture.editability != .editable { .targetNotEditable }
            else if strategy.replaceViaAccessibilityWrite || !strategy.undoVerified { .notUndoable }
            else { nil }
        case .flagged: .flagged
        default: .notReady
        }
        if let declined {
            directApplyDeclined = declined
            presentPicker()
            return
        }
        appliedDirectly = true
        await apply(pasteAnyway: false)
    }

    private func fail(_ failure: Failure) {
        state = .failed(failure, partial: "")
        presentPicker()
    }

    /// Shows the picker once. Anything that needs the user — a refusal, a failure, a gate
    /// waiting for Return — ends a direct apply and shows it, with the reason.
    private func presentPicker() {
        if isDirectApply {
            isDirectApply = false
            if directApplyDeclined == nil { directApplyDeclined = .notReady }
        }
        guard !pickerShown else { return }
        pickerShown = true
        onEffect(.showPicker)
        if let startedAt, timings.captureToPicker == nil {
            timings.captureToPicker = Self.milliseconds(since: startedAt)
            if let captureInterval { QuillSignposts.signposter.endInterval(QuillSignposts.capture, captureInterval) }
        }
    }

    // MARK: Keys

    func handle(_ key: PickerKey) async {
        switch state {
        case .idle, .capturing, .applying, .applied, .closed:
            if key == .escape || key == .shortcut, state == .capturing { close() }

        case .refusedCapture:
            if key == .returnKey || key == .escape || key == .shortcut { close() }

        case .awaitingConsent(let notice):
            switch key {
            case .returnKey: await acceptConsent(notice)
            case .number, .tab: await changeProfile(key)
            case .escape, .shortcut: close()
            default: break
            }

        case .waitingToStart:
            switch key {
            case .returnKey: await begin(confirmed: true)
            case .number, .tab: await changeProfile(key)
            case .escape, .shortcut: close()
            default: break
            }

        case .generating:
            switch key {
            case .number, .tab:
                cancelGeneration()
                await changeProfile(key)
            case .escape, .shortcut:
                cancelGeneration()
                close()
            default: break
            }

        case .ready(let text):
            switch key {
            case .returnKey: await apply(pasteAnyway: false)
            case .optionReturn where capture?.editability == .uncertain: await apply(pasteAnyway: true)
            case .commandC: await copy(text, resume: .ready)
            case .number, .tab: await changeProfile(key)
            case .commandE: startCorrecting(text, from: .ready(text))
            case .d: showsDiff.toggle()
            case .r: await rerun()
            case .escape, .shortcut: close()
            default: break
            }

        case .flagged(let text, let flags):
            switch key {
            // Confirming the flags makes it Ready; applying is a second, separate key.
            case .commandReturn: state = .ready(text: text)
            case .commandC: await copy(text, resume: .flagged(flags))
            case .number, .tab: await changeProfile(key)
            case .commandE: startCorrecting(text, from: .flagged(text, flags))
            case .d: showsDiff.toggle()
            case .r: await rerun()
            case .escape, .shortcut: close()
            default: break
            }

        case .noChanges:
            let original = capture?.text ?? ""
            switch key {
            case .returnKey, .escape, .shortcut: close()
            case .commandC: await copy(original, resume: .noChanges)
            case .number, .tab: await changeProfile(key)
            case .commandE: startCorrecting(original, from: .noChanges)
            case .r: await rerun()
            default: break
            }

        case .truncated, .refused:
            switch key {
            case .number, .tab: await changeProfile(key)
            case .r: await rerun()
            case .escape, .shortcut: close()
            default: break
            }

        case .failed(let failure, _):
            switch key {
            case .returnKey:
                switch Self.action(for: failure) {
                case .openSettings: onEffect(.openSettings(.providers))
                case .retry: await rerun()
                }
            case .number, .tab: await changeProfile(key)
            case .r: await rerun()
            case .escape, .shortcut: close()
            default: break
            }

        case .tooLong(_, let suggestion):
            switch key {
            case .returnKey:
                guard let suggestion else { return }
                usedSuggestion = true
                model = suggestion
                await begin()
            case .number, .tab: await changeProfile(key)
            case .escape, .shortcut: close()
            default: break
            }

        case .correcting(let correction):
            switch key {
            // Return inserts a line break in the field; the session does nothing.
            case .commandReturn: await commitCorrection(correction)
            case .escape, .shortcut: state = Self.restore(correction.previous)
            default: break
            }

        case .waitingForClipboard:
            if key == .escape || key == .shortcut { close() }
        }
    }

    enum FailureAction: Equatable { case openSettings, retry }

    /// Return in Failed: the presentation mapping's action — retry, or open Settings.
    static func action(for failure: Failure) -> FailureAction {
        switch Presentation.failure(failure).action {
        case .retry?: .retry
        case nil: .retry
        case .openProviderSettings?, .openAppleIntelligenceSettings?, .openAccessibilitySettings?,
             .openPasteSettings?, .openCaptureSettings?: .openSettings
        }
    }

    private func changeProfile(_ key: PickerKey) async {
        guard !profileList.isEmpty else { return }
        let next: Profile?
        switch key {
        case .number(let position):
            next = profileList.indices.contains(position - 1) ? profileList[position - 1] : nil
        case .tab:
            let index = profile.flatMap { current in profileList.firstIndex { $0.id == current.id } } ?? -1
            next = profileList[(index + 1) % profileList.count]
        default:
            next = nil
        }
        guard let next else { return }
        activeInstruction = nil
        instructionDraft = ""
        profile = next
        let current = (try? settings.settings()) ?? QuillSettings()
        model = next.model ?? current.globalModel
        usedSuggestion = false
        await begin()
    }

    private func rerun() async {
        await begin()
    }

    // MARK: Pointer and instruction

    /// A click on a profile: the same as its number key.
    func selectProfile(at index: Int) async {
        await handle(.number(index + 1))
    }

    /// Return in the picker: sends a pending instruction, otherwise it is the state's
    /// Return (apply, send, start…).
    func pressReturn() async {
        if instructionPending, acceptsInstruction {
            await submitInstruction()
        } else {
            await handle(.returnKey)
        }
    }

    /// The states an instruction may start from: the text is captured and nothing is
    /// being applied, corrected or waited for.
    var acceptsInstruction: Bool {
        guard capture != nil else { return false }
        switch state {
        case .awaitingConsent, .waitingToStart, .generating, .ready, .flagged, .noChanges, .truncated, .refused,
             .failed, .tooLong:
            return true
        case .idle, .capturing, .refusedCapture, .correcting, .waitingForClipboard, .applying, .applied, .closed:
            return false
        }
    }

    /// Rewrites the selection with what the user typed (PRODUCT §4.1, "Instruction").
    /// It runs on the global model, through the same consent, guards and keys as a
    /// profile.
    func submitInstruction() async {
        let text = instructionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, acceptsInstruction else { return }
        cancelGeneration()
        activeInstruction = text
        profile = Self.instructionProfile()
        let current = (try? settings.settings()) ?? QuillSettings()
        model = current.globalModel ?? model
        usedSuggestion = false
        await begin()
    }

    /// The fixed id of the instruction's profile: consent records and the last used
    /// profile never collect one id per instruction.
    static let instructionProfileID = UUID(uuidString: "6A2F0E54-3C1B-4E0D-9B7A-5D8C1F2E3A40")!

    /// The base an instruction runs on. Names, numbers and links are kept; the length
    /// band is wide, because "shorter" or "as a list" are what instructions ask for; the
    /// instruction decides tone, register and language (`PromptComposer.instructionRuleIDs`).
    /// It is never stored, and never listed with the profiles.
    static func instructionProfile() -> Profile {
        Profile(id: instructionProfileID, name: PickerCopy.string("picker.instruction.profile"), symbol: "wand.and.stars",
                settings: ProfileSettings(scope: .rewrite, emoji: .remove, preserve: [.names, .numbers, .links],
                                          lengthBand: ProfileSettings.LengthBand(0.05, ProfileLimits.maximumLengthRatio)))
    }

    private func cancelGeneration() {
        generationNumber += 1
        generationTask?.cancel()
        generationTask = nil
    }

    private func close() {
        cancelGeneration()
        state = .closed
        onEffect(.close)
    }

    // MARK: Apply and copy

    private func apply(pasteAnyway: Bool) async {
        guard let capture, case .ready(let text) = state else { return }
        // Read-only-only and uncertain targets copy on Return; Paste anyway is ⌥Return.
        if capture.editability == .readOnlyOnly || (capture.editability == .uncertain && !pasteAnyway) {
            guard await selection.copy(text) else { return await waitForClipboard(text, resume: .ready) }
            return finishApplied(.replace(.copiedNotEditable))
        }
        state = .applying
        let replaceStart = ContinuousClock.now
        let interval = QuillSignposts.signposter.beginInterval(QuillSignposts.replace)
        let outcome = await selection.replace(text, capture: capture, pasteAnyway: pasteAnyway)
        QuillSignposts.signposter.endInterval(QuillSignposts.replace, interval)
        timings.replace = Self.milliseconds(since: replaceStart)
        if outcome == .clipboardBusy { return await waitForClipboard(text, resume: .ready) }
        finishApplied(.replace(outcome))
    }

    private func copy(_ text: String, resume: SessionState.Resume) async {
        guard await selection.copy(text) else { return await waitForClipboard(text, resume: resume) }
        finishApplied(.copied)
    }

    private func waitForClipboard(_ text: String, resume: SessionState.Resume) async {
        state = .waitingForClipboard(text: text, resume: resume)
        await selection.clipboardReadFinished()
        guard case .waitingForClipboard = state else { return }
        state = switch resume {
        case .ready: .ready(text: text)
        case .flagged(let flags): .flagged(text: text, flags: flags)
        case .noChanges: .noChanges
        }
    }

    private func finishApplied(_ outcome: AppliedOutcome) {
        state = .applied(outcome)
        onEffect(.close)
        onEffect(.toast(outcome, profile: profile?.name ?? "", direct: appliedDirectly))
    }

    // MARK: Correcting

    private func startCorrecting(_ text: String, from previous: Correction.PreviousState) {
        let input = capture?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tooLong = input.count > ProfileLimits.exampleSideCharacters || text.count > ProfileLimits.exampleSideCharacters
        state = .correcting(Correction(text: text, saveAsExample: false,
                                       saveDisabledReason: tooLong ? .tooLong : nil, pending: nil, previous: previous))
    }

    func updateCorrection(_ text: String) {
        guard case .correcting(var correction) = state else { return }
        correction.text = text
        let input = capture?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tooLong = input.count > ProfileLimits.exampleSideCharacters || text.count > ProfileLimits.exampleSideCharacters
        correction.saveDisabledReason = tooLong ? .tooLong : nil
        if tooLong { correction.saveAsExample = false }
        state = .correcting(correction)
    }

    func setSaveAsExample(_ on: Bool) {
        guard case .correcting(var correction) = state, correction.saveDisabledReason == nil else { return }
        correction.saveAsExample = on
        state = .correcting(correction)
    }

    /// ⌘Return: the corrected text becomes the result and the guards run again on it.
    private func commitCorrection(_ correction: Correction) async {
        guard let profile, let capture else { return }
        let input = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = correction.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !corrected.isEmpty else { return }
        if correction.saveAsExample, correction.saveDisabledReason == nil {
            let example = Example(input: input, output: corrected)
            let found = PersonalDataScreen.findings(in: input).union(PersonalDataScreen.findings(in: corrected))
            if !found.isEmpty {
                var pending = correction
                pending.pending = .personalData(found)
                state = .correcting(pending)
                return
            }
            if !saveExample(example, profile: profile, correction: correction) { return }
        }
        state = resultState(corrected)
    }

    /// The personal-identifier decision: neutral stand-ins, or no example at all.
    func resolvePersonalData(useStandIns: Bool) {
        guard case .correcting(let correction) = state, case .personalData = correction.pending,
              let profile, let capture else { return }
        let corrected = correction.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if useStandIns {
            let input = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let example = examples.neutralized(Example(input: input, output: corrected))
            if !saveExample(example, profile: profile, correction: correction) { return }
        }
        state = resultState(corrected)
    }

    /// The 8-example decision: which one the new example replaces (nil: keep editing).
    func chooseExampleToReplace(_ id: UUID?) {
        guard case .correcting(var correction) = state, case .chooseReplacement = correction.pending,
              let profile, let capture else { return }
        guard let id else {
            correction.pending = nil
            state = .correcting(correction)
            return
        }
        let corrected = correction.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var example = Example(input: input, output: corrected)
        if !PersonalDataScreen.isClean(input) || !PersonalDataScreen.isClean(corrected) {
            example = examples.neutralized(example)
        }
        do {
            self.profile = try examples.save(example, to: profile.id, replacing: id)
        } catch {
            log.error("could not save the example: \(error)")
            return
        }
        state = resultState(corrected)
    }

    /// Saves, or asks which example to replace when the profile is full. Returns
    /// whether the commit may go on.
    private func saveExample(_ example: Example, profile: Profile, correction: Correction) -> Bool {
        if profile.examples.count >= ProfileLimits.examples {
            var pending = correction
            pending.pending = .chooseReplacement(profile.examples)
            state = .correcting(pending)
            return false
        }
        do {
            self.profile = try examples.save(example, to: profile.id, replacing: nil)
            return true
        } catch {
            log.error("could not save the example: \(error)")
            return false
        }
    }

    /// The guards run again on a corrected text; a formatting-loss flag stays, because
    /// the capture's formatting has not changed.
    private func resultState(_ corrected: String) -> SessionState {
        guard let profile, let capture else { return .ready(text: corrected) }
        let input = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let checked = guards.evaluate(
            input: input, output: corrected,
            context: .init(settings: profile.settings, examples: profile.examples,
                           formatting: Self.formatting(capture.formatting)))
        let (leading, _, trailing) = Self.edges(capture.text)
        switch checked.verdict {
        case .result(let text, let flags):
            let full = leading + text + trailing
            return flags.isEmpty ? .ready(text: full) : .flagged(text: full, flags: flags)
        case .noChanges:
            return .noChanges
        case .empty, .refused:
            return .ready(text: leading + corrected + trailing)
        }
    }

    private static func restore(_ previous: Correction.PreviousState) -> SessionState {
        switch previous {
        case .ready(let text): .ready(text: text)
        case .flagged(let text, let flags): .flagged(text: text, flags: flags)
        case .noChanges: .noChanges
        }
    }

    static func edges(_ text: String) -> (String, String, String) {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
              let last = text.lastIndex(where: { !$0.isWhitespace }) else { return (text, "", "") }
        return (String(text[..<first]), String(text[first...last]), String(text[text.index(after: last)...]))
    }

    static func formatting(_ state: FormattingState) -> CaptureFormatting {
        switch state {
        case .rich: .rich
        case .plain: .plain
        case .unknown: .unknown
        }
    }
}
