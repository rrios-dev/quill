import CoreGraphics
import Foundation
import ModelKit
import RewriteKit
import SelectionKit
import Testing

@testable import Quill

/// A session over temporary stores, fake selection, fake providers and the real engine.
@MainActor
final class SessionHarness {
    static let input = "the meeting is moved to friday"
    static let app = AppIdentity(pid: 4242, bundleIdentifier: "com.example.editor")

    let folder: URL
    let settings: SettingsStore
    let profiles: ProfileStore
    let local = FakeProvider(id: "apple.on-device", name: "Apple Intelligence", onDevice: true, context: 4_096)
    let bigLocal = FakeProvider(id: "custom-bigmodel", name: "Big local", onDevice: true, context: 200_000)
    let hosted = FakeProvider(id: "openrouter", name: "OpenRouter", onDevice: false, context: nil)
    let selection: FakeSelection
    let catalog = FakeCatalog()
    let sink: FakeExampleSink
    let session: RewriteSession
    private(set) var effects: [SessionEffect] = []
    /// The profile the tests start on: plain rewrite rules, so a sensible reply is clean.
    let test: Profile

    var localModel: ModelSelection { ModelSelection(provider: local.descriptor.id, model: "system") }
    var hostedModel: ModelSelection { ModelSelection(provider: hosted.descriptor.id, model: "vendor/model") }
    var bigLocalModel: ModelSelection { ModelSelection(provider: bigLocal.descriptor.id, model: "big") }

    init(capture: Capture? = nil, globalModel: ModelSelection? = nil, notified: Bool = true,
         treatLoopbackAsRemote: Bool = false) throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RewriteSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        settings = SettingsStore(dataDirectory: folder)
        profiles = ProfileStore(dataDirectory: folder)
        try profiles.seedIfEmpty(language: "en")
        var settingsForTest = ProfileSettings(scope: .rewrite)
        settingsForTest.preserve = []
        settingsForTest.lengthBand = .init(0.2, 5)
        test = try profiles.save(Profile(name: "Test", symbol: "pencil", settings: settingsForTest))
        selection = FakeSelection(capture: capture ?? Self.capture())
        sink = FakeExampleSink(profiles: profiles)
        let holder = try ProviderRegistryHolder(shipped: [local, bigLocal, hosted], customServers: [], makeCustom: { _ in fatalError() })
        session = RewriteSession(settings: settings, profiles: profiles, registry: holder,
                                 engine: try GenerationEngine(), guards: try OutputGuards(), selection: selection,
                                 catalog: catalog, examples: sink, treatLoopbackAsRemote: treatLoopbackAsRemote)
        let global = globalModel ?? localModel
        let testID = test.id
        let hostedID = hosted.descriptor.id
        try settings.update {
            $0.globalModel = global
            $0.lastUsedProfile = testID
            if notified { $0.notifiedProviders = [hostedID] }
        }
        session.onEffect = { [weak self] in self?.effects.append($0) }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    static func capture(_ text: String = input, editability: Editability = .editable,
                        formatting: FormattingState = .plain, app: AppIdentity = app) -> Capture {
        Capture(text: text, app: app, editability: editability, formatting: formatting, method: .accessibility)
    }

    func start() async {
        await session.start(.hotKey(app: Self.app, hotKeyCode: 15))
        await session.settle()
    }

    func press(_ key: PickerKey) async {
        await session.handle(key)
        await session.settle()
    }

    var streams: Int { local.streamInputs.count + bigLocal.streamInputs.count + hosted.streamInputs.count }
}

// MARK: Every key in every state (PRODUCT §4.1)

/// What a key should do in a state, as PRODUCT §4.1 says.
enum Expectation: String {
    case nothing, close, start, replace, pasteAnyway, copy, rerun, changeProfile, correct, diff, confirm,
         commit, back, settings, rerunSuggested
}

/// The states the table has a row for, each reachable from a fresh harness.
enum Row: String, CaseIterable {
    case refusedCapture, awaitingConsent, waitingToStart, generating, readyEditable, readyUncertain,
         readyReadOnly, flagged, noChanges, truncated, refused, failed, tooLong, correcting,
         waitingForClipboard, applied

    func expectation(_ key: PickerKey) -> Expectation {
        switch (self, key) {
        case (.refusedCapture, .returnKey), (.refusedCapture, .escape), (.refusedCapture, .shortcut): .close
        case (.refusedCapture, _): .nothing

        case (.awaitingConsent, .returnKey), (.waitingToStart, .returnKey): .start
        case (.awaitingConsent, .number), (.awaitingConsent, .tab),
             (.waitingToStart, .number), (.waitingToStart, .tab): .changeProfile
        case (.awaitingConsent, .escape), (.awaitingConsent, .shortcut),
             (.waitingToStart, .escape), (.waitingToStart, .shortcut): .close
        case (.awaitingConsent, _), (.waitingToStart, _): .nothing

        case (.generating, .number), (.generating, .tab): .changeProfile
        case (.generating, .escape), (.generating, .shortcut): .close
        case (.generating, _): .nothing

        case (.readyEditable, .returnKey): .replace
        case (.readyUncertain, .returnKey), (.readyReadOnly, .returnKey): .copy
        case (.readyUncertain, .optionReturn): .pasteAnyway
        case (.readyEditable, .commandC), (.readyUncertain, .commandC), (.readyReadOnly, .commandC),
             (.flagged, .commandC), (.noChanges, .commandC): .copy
        case (.readyEditable, .number), (.readyEditable, .tab), (.readyUncertain, .number), (.readyUncertain, .tab),
             (.readyReadOnly, .number), (.readyReadOnly, .tab), (.flagged, .number), (.flagged, .tab),
             (.noChanges, .number), (.noChanges, .tab), (.truncated, .number), (.truncated, .tab),
             (.refused, .number), (.refused, .tab), (.failed, .number), (.failed, .tab),
             (.tooLong, .number), (.tooLong, .tab): .changeProfile
        case (.readyEditable, .commandE), (.readyUncertain, .commandE), (.readyReadOnly, .commandE),
             (.flagged, .commandE), (.noChanges, .commandE): .correct
        case (.readyEditable, .d), (.readyUncertain, .d), (.readyReadOnly, .d), (.flagged, .d): .diff
        case (.readyEditable, .r), (.readyUncertain, .r), (.readyReadOnly, .r), (.flagged, .r),
             (.noChanges, .r), (.truncated, .r), (.refused, .r), (.failed, .r): .rerun
        case (.readyEditable, .escape), (.readyEditable, .shortcut), (.readyUncertain, .escape),
             (.readyUncertain, .shortcut), (.readyReadOnly, .escape), (.readyReadOnly, .shortcut),
             (.flagged, .escape), (.flagged, .shortcut), (.noChanges, .escape), (.noChanges, .shortcut),
             (.noChanges, .returnKey), (.truncated, .escape), (.truncated, .shortcut), (.refused, .escape),
             (.refused, .shortcut), (.failed, .escape), (.failed, .shortcut), (.tooLong, .escape),
             (.tooLong, .shortcut): .close
        case (.flagged, .commandReturn): .confirm
        case (.failed, .returnKey): .settings
        case (.tooLong, .returnKey): .rerunSuggested

        case (.correcting, .commandReturn): .commit
        case (.correcting, .escape), (.correcting, .shortcut): .back
        case (.waitingForClipboard, .escape), (.waitingForClipboard, .shortcut): .close

        default: .nothing
        }
    }

    /// Builds a harness and drives it into this row's state.
    @MainActor
    func reach() async throws -> SessionHarness {
        switch self {
        case .refusedCapture:
            let harness = try SessionHarness()
            harness.selection.captureResult = .failure(.noSelection)
            await harness.start()
            return harness
        case .awaitingConsent:
            let harness = try SessionHarness(notified: false)
            try harness.settings.update { [model = harness.hostedModel] in $0.globalModel = model }
            await harness.start()
            return harness
        case .waitingToStart:
            let long = Array(repeating: "word", count: RewriteSession.largeTextWords + 1).joined(separator: " ")
            let harness = try SessionHarness(capture: SessionHarness.capture(long))
            try harness.settings.update { [model = harness.hostedModel] in $0.globalModel = model }
            await harness.start()
            return harness
        case .generating:
            let harness = try SessionHarness()
            harness.local.hold = true
            await harness.session.start(.hotKey(app: SessionHarness.app, hotKeyCode: 15))
            try await waitUntil { if case .generating(let partial) = harness.session.state { !partial.isEmpty } else { false } }
            return harness
        case .readyEditable, .readyUncertain, .readyReadOnly:
            let editability: Editability = self == .readyEditable ? .editable : self == .readyUncertain ? .uncertain : .readOnlyOnly
            let harness = try SessionHarness(capture: SessionHarness.capture(editability: editability))
            await harness.start()
            return harness
        case .flagged:
            let harness = try SessionHarness()
            harness.local.reply = "Dear [Name], the meeting has moved to Friday."
            await harness.start()
            return harness
        case .noChanges:
            let harness = try SessionHarness()
            harness.local.reply = SessionHarness.input
            await harness.start()
            return harness
        case .truncated:
            let harness = try SessionHarness()
            harness.local.finish = .length
            await harness.start()
            return harness
        case .refused:
            let harness = try SessionHarness()
            harness.local.error = ProviderError(.refused, "no")
            await harness.start()
            return harness
        case .failed:
            let harness = try SessionHarness()
            harness.local.error = ProviderError(.authentication, "bad key")
            await harness.start()
            return harness
        case .tooLong:
            let long = String(repeating: "lorem ipsum dolor ", count: 2_000)
            let harness = try SessionHarness(capture: SessionHarness.capture(long))
            harness.catalog.alternativeModels = [ModelCandidate(selection: harness.bigLocalModel, contextTokens: 200_000, runsOnDevice: true)]
            await harness.start()
            return harness
        case .correcting:
            let harness = try SessionHarness()
            await harness.start()
            await harness.press(.commandE)
            return harness
        case .waitingForClipboard:
            let harness = try SessionHarness()
            harness.selection.copyAnswers = [false]
            await harness.start()
            Task { await harness.session.handle(.commandC) }
            try await waitUntil { harness.selection.isWaitingForClipboard }
            return harness
        case .applied:
            let harness = try SessionHarness()
            await harness.start()
            await harness.press(.returnKey)
            return harness
        }
    }
}

@MainActor
func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(5)) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw WaitTimeout() }
        try await Task.sleep(for: .milliseconds(5))
    }
}

struct WaitTimeout: Error {}

/// A coarse label of a state, enough to tell what a key changed.
func kind(_ state: SessionState) -> String {
    switch state {
    case .idle: "idle"
    case .capturing: "capturing"
    case .refusedCapture: "refusedCapture"
    case .awaitingConsent: "awaitingConsent"
    case .waitingToStart: "waitingToStart"
    case .generating: "generating"
    case .ready: "ready"
    case .flagged: "flagged"
    case .noChanges: "noChanges"
    case .truncated: "truncated"
    case .refused: "refused"
    case .failed: "failed"
    case .tooLong: "tooLong"
    case .correcting: "correcting"
    case .waitingForClipboard: "waitingForClipboard"
    case .applying: "applying"
    case .applied: "applied"
    case .closed: "closed"
    }
}

@Suite("Rewrite session: every key in every state", .serialized)
@MainActor
struct RewriteSessionKeyTableTests {
    @Test("PRODUCT §4.1", arguments: Row.allCases)
    func row(_ row: Row) async throws {
        for key in PickerKey.allCases {
            let harness = try await row.reach()
            let before = harness.session.state
            let streamsBefore = harness.streams
            let effectsBefore = harness.effects.count
            let profileBefore = harness.session.profile?.id
            let diffBefore = harness.session.showsDiff
            if row == .generating, key != .number(1), key != .tab, key != .escape, key != .shortcut {
                await harness.session.handle(key)
            } else {
                await harness.press(key)
            }
            let after = harness.session.state
            let newEffects = Array(harness.effects.dropFirst(effectsBefore))
            let context = "\(row) × \(key): \(kind(before)) → \(kind(after)), effects \(newEffects)"
            switch row.expectation(key) {
            case .nothing:
                #expect(kind(after) == kind(before), "\(context)")
                #expect(harness.streams == streamsBefore, "\(context)")
                #expect(harness.selection.replaced.isEmpty && harness.selection.copied.isEmpty || row == .applied, "\(context)")
                #expect(harness.session.showsDiff == diffBefore, "\(context)")
                #expect(!newEffects.contains(.close), "\(context)")
            case .close:
                #expect(after == .closed, "\(context)")
                #expect(newEffects.contains(.close), "\(context)")
                #expect(harness.selection.replaced.isEmpty, "\(context)")
                if row == .awaitingConsent || row == .waitingToStart {
                    #expect(harness.streams == 0, "nothing is sent: \(context)")
                }
            case .start:
                #expect(harness.streams == streamsBefore + 1, "\(context)")
            case .replace:
                #expect(harness.selection.replaced.count == 1 && harness.selection.replaced.first?.pasteAnyway == false, "\(context)")
                #expect(after == .applied(.replace(.replaced)), "\(context)")
            case .pasteAnyway:
                #expect(harness.selection.replaced.count == 1 && harness.selection.replaced.first?.pasteAnyway == true, "\(context)")
            case .copy:
                #expect(harness.selection.copied.count == 1, "\(context)")
                #expect(harness.selection.replaced.isEmpty, "\(context)")
                #expect(kind(after) == "applied", "\(context)")
            case .rerun:
                #expect(harness.streams == streamsBefore + 1, "\(context)")
                #expect(harness.session.profile?.id == profileBefore, "\(context)")
            case .changeProfile:
                #expect(harness.session.profile?.id != profileBefore, "\(context)")
                if row == .awaitingConsent || row == .waitingToStart {
                    #expect(harness.streams == 0 || kind(after) == "generating" || kind(after) != kind(before), "\(context)")
                } else if row != .tooLong {
                    #expect(harness.streams == streamsBefore + 1, "\(context)")
                }
            case .correct:
                #expect(kind(after) == "correcting", "\(context)")
            case .diff:
                #expect(harness.session.showsDiff != diffBefore, "\(context)")
                #expect(kind(after) == kind(before), "\(context)")
            case .confirm:
                #expect(kind(after) == "ready", "\(context)")
                #expect(harness.selection.replaced.isEmpty, "a flagged result is not applied by ⌘Return: \(context)")
            case .commit:
                #expect(kind(after) == "ready" || kind(after) == "flagged", "\(context)")
            case .back:
                #expect(kind(after) == "ready", "\(context)")
            case .settings:
                #expect(newEffects.contains(.openSettings(.providers)), "\(context)")
            case .rerunSuggested:
                #expect(harness.bigLocal.streamInputs.count == 1, "\(context)")
            }
            harness.local.releaseHold()
            harness.selection.finishClipboardRead()
            await harness.session.settle()
        }
    }
}

// MARK: The rules the table rests on

@Suite("Rewrite session", .serialized)
@MainActor
struct RewriteSessionTests {
    @Test("a flagged result is never applied without ⌘Return; after it, Return applies")
    func flaggedNeedsConfirmation() async throws {
        let harness = try await Row.flagged.reach()
        guard case .flagged = harness.session.state else { Issue.record("not flagged: \(harness.session.state)"); return }
        await harness.press(.returnKey)
        await harness.press(.optionReturn)
        #expect(harness.selection.replaced.isEmpty)
        await harness.press(.commandReturn)
        await harness.press(.returnKey)
        #expect(harness.selection.replaced.count == 1)
    }

    @Test("a flagged result on an uncertain target needs both ⌘Return and ⌥Return")
    func flaggedUncertainNeedsBoth() async throws {
        let harness = try SessionHarness(capture: SessionHarness.capture(editability: .uncertain))
        harness.local.reply = "Dear [Name], the meeting has moved to Friday."
        await harness.start()
        await harness.press(.optionReturn)
        #expect(harness.selection.replaced.isEmpty)
        await harness.press(.commandReturn)
        await harness.press(.optionReturn)
        #expect(harness.selection.replaced.first?.pasteAnyway == true)
    }

    @Test("a picker apply closes the picker and toasts the outcome, not as a direct apply")
    func pickerApplyToasts() async throws {
        let harness = try await Row.readyEditable.reach()
        await harness.press(.returnKey)
        #expect(harness.effects.suffix(2) == [.close, .toast(.replace(.replaced), profile: "Test", direct: false)])
    }

    @Test("Paste anyway is never offered on read-only-only apps")
    func noPasteAnywayOnReadOnly() async throws {
        let harness = try await Row.readyReadOnly.reach()
        await harness.press(.optionReturn)
        #expect(harness.selection.replaced.isEmpty)
        await harness.press(.returnKey)
        #expect(harness.selection.replaced.isEmpty)
        #expect(harness.session.state == .applied(.replace(.copiedNotEditable)))
    }

    @Test("partial text is never copied or applied")
    func partialNeverLeaves() async throws {
        for row in [Row.truncated, .failed] {
            let harness = try await row.reach()
            for key in [PickerKey.commandC, .returnKey, .optionReturn, .commandReturn] { await harness.press(key) }
            #expect(harness.selection.copied.isEmpty && harness.selection.replaced.isEmpty, "\(row)")
        }
    }

    @Test("prewarm is requested when the hot key fires")
    func prewarms() async throws {
        let harness = try SessionHarness()
        await harness.start()
        try await waitUntil { harness.local.prewarms == 1 }
    }

    @Test("a pinned model whose provider is unavailable yields Choose a model, never another provider")
    func pinnedUnavailable() async throws {
        let harness = try SessionHarness()
        var pinned = harness.test
        pinned.model = harness.hostedModel
        _ = try harness.profiles.save(pinned)
        harness.hosted.availabilityValue = .unavailable(.missingCredential)
        await harness.start()
        #expect(harness.session.state == .failed(.chooseModel(profile: "Test"), partial: ""))
        #expect(harness.streams == 0)
        await harness.press(.returnKey)
        #expect(harness.effects.contains(.openSettings(.providers)))
    }

    @Test("no model at all asks to choose one")
    func noModel() async throws {
        let harness = try SessionHarness()
        try harness.settings.update { $0.globalModel = nil }
        await harness.start()
        #expect(harness.session.state == .failed(.chooseModel(profile: "Test"), partial: ""))
    }

    @Test("nothing is sent while awaiting consent; Esc sends nothing; Return records it and starts")
    func consent() async throws {
        let refused = try await Row.awaitingConsent.reach()
        guard case .awaitingConsent(let notice) = refused.session.state else { Issue.record("\(refused.session.state)"); return }
        #expect(notice.firstUseOfProvider)
        #expect(notice.recipients == [.named("OpenRouter"), .routedInferenceProvider])
        #expect(refused.streams == 0)
        await refused.press(.escape)
        #expect(refused.streams == 0)
        #expect(try refused.settings.settings().notifiedProviders.isEmpty)

        let accepted = try await Row.awaitingConsent.reach()
        await accepted.press(.returnKey)
        #expect(accepted.hosted.streamInputs.count == 1)
        #expect(try accepted.settings.settings().notifiedProviders.contains("openrouter"))
    }

    @Test("a profile's own examples to a new recipient ask once per profile")
    func userTextToNewRecipient() async throws {
        let harness = try SessionHarness()
        var mine = harness.test
        mine.examples = [Example(input: "see u", output: "See you.")]
        _ = try harness.profiles.save(mine)
        try harness.settings.update { [model = harness.hostedModel] in $0.globalModel = model }
        await harness.start()
        guard case .awaitingConsent(let notice) = harness.session.state else { Issue.record("\(harness.session.state)"); return }
        #expect(!notice.firstUseOfProvider && notice.profileTextToNewRecipient)
        await harness.press(.returnKey)
        #expect(try harness.settings.settings().acceptedRecipients[mine.id] == ["openrouter"])

        await harness.start()
        #expect(kind(harness.session.state) == "ready")
    }

    @Test("shipped examples and guidance do not count as user text")
    func shippedTextIsNotUserText() throws {
        let profiles = try BuiltInProfiles.all(language: "es") + BuiltInProfiles.all(language: "en")
        for profile in profiles { #expect(!BuiltInProfiles.hasUserAuthoredText(profile), "\(profile.name)") }
        var edited = profiles[1]
        edited.guidance += " Mine."
        #expect(BuiltInProfiles.hasUserAuthoredText(edited))
    }

    @Test("a large hosted text waits for Return with its word count and estimated cost")
    func largeHostedText() async throws {
        let harness = try await Row.waitingToStart.reach()
        guard case .waitingToStart(let notice) = harness.session.state else { Issue.record("\(harness.session.state)"); return }
        #expect(notice.reason == .largeText && notice.words == RewriteSession.largeTextWords + 1)
        #expect(notice.estimatedCost == nil)

        let priced = try SessionHarness(capture: SessionHarness.capture(
            Array(repeating: "word", count: 2_000).joined(separator: " ")))
        try priced.settings.update { [model = priced.hostedModel] in $0.globalModel = model }
        priced.catalog.descriptors = [priced.hostedModel: ModelDescriptor(
            id: "vendor/model", pricing: ModelPricing(inputPerMillion: 1, outputPerMillion: 2))]
        await priced.start()
        guard case .waitingToStart(let pricedNotice) = priced.session.state else { Issue.record("\(priced.session.state)"); return }
        #expect((pricedNotice.estimatedCost ?? 0) > 0)
    }

    @Test("a large text to a new hosted provider is one step: consent carries the count")
    func consentAndLargeTextAreOneStep() async throws {
        let long = Array(repeating: "word", count: 2_000).joined(separator: " ")
        let harness = try SessionHarness(capture: SessionHarness.capture(long), notified: false)
        try harness.settings.update { [model = harness.hostedModel] in $0.globalModel = model }
        await harness.start()
        guard case .awaitingConsent(let notice) = harness.session.state else { Issue.record("\(harness.session.state)"); return }
        #expect(notice.largeText?.words == 2_000)
        await harness.press(.returnKey)
        #expect(harness.hosted.streamInputs.count == 1)
    }

    @Test("Services: a hosted rewrite waits for Return; an on-device one starts")
    func services() async throws {
        let hosted = try SessionHarness()
        try hosted.settings.update { [model = hosted.hostedModel] in $0.globalModel = model }
        await hosted.session.start(.services(SessionHarness.capture()))
        await hosted.session.settle()
        guard case .waitingToStart(let notice) = hosted.session.state else { Issue.record("\(hosted.session.state)"); return }
        #expect(notice.reason == .services)
        #expect(hosted.streams == 0)
        #expect(hosted.local.prewarms == 0)

        let local = try SessionHarness()
        await local.session.start(.services(SessionHarness.capture()))
        await local.session.settle()
        #expect(kind(local.session.state) == "ready")
    }

    @Test("the loopback debug hook sends a local server through the hosted paths")
    func treatLoopbackAsRemote() async throws {
        let harness = try SessionHarness(treatLoopbackAsRemote: true)
        try harness.settings.update { [model = harness.bigLocalModel] in $0.globalModel = model }
        await harness.start()
        #expect(kind(harness.session.state) == "awaitingConsent")
        #expect(harness.streams == 0)
    }

    @Test("a too-long text on an on-device model is never offered a hosted model")
    func tooLongSuggestsOnlyLocal() async throws {
        let long = String(repeating: "lorem ipsum dolor ", count: 2_000)
        let harness = try SessionHarness(capture: SessionHarness.capture(long))
        harness.catalog.alternativeModels = [
            ModelCandidate(selection: harness.hostedModel, contextTokens: 1_000_000, runsOnDevice: false),
        ]
        await harness.start()
        #expect(harness.session.state == .tooLong(model: harness.localModel, suggestion: nil))
        await harness.press(.returnKey)
        #expect(harness.streams == 0)

        let withLocal = try await Row.tooLong.reach()
        #expect(withLocal.session.state == .tooLong(model: withLocal.localModel, suggestion: withLocal.bigLocalModel))
        await withLocal.press(.returnKey)
        #expect(withLocal.bigLocal.streamInputs.count == 1)
    }

    @Test("the profile resolves next-rewrite (once) › app default › last used; a stale default is noted")
    func resolution() async throws {
        let harness = try SessionHarness()
        let all = try harness.profiles.all().profiles
        let work = try #require(all.first { $0.builtIn == .work })
        let formal = try #require(all.first { $0.builtIn == .formal })
        try harness.settings.update { $0.nextRewriteProfile = work.id; $0.appDefaults[SessionHarness.app.bundleIdentifier!] = formal.id }
        await harness.start()
        #expect(harness.session.profile?.id == work.id)
        #expect(try harness.settings.settings().nextRewriteProfile == nil)
        await harness.start()
        #expect(harness.session.profile?.id == formal.id)

        // The app default now names a deleted profile: the last used, with a note.
        try harness.settings.update { $0.lastUsedProfile = work.id }
        try harness.profiles.delete(formal.id)
        await harness.start()
        #expect(harness.session.staleAppDefault)
        #expect(harness.session.profile?.id == work.id)
        #expect(harness.effects.contains(.showPicker))
    }

    @Test("generating: a profile key cancels and restarts with that profile")
    func restartWhileGenerating() async throws {
        let harness = try await Row.generating.reach()
        await harness.session.handle(.number(1))
        harness.local.releaseHold()
        await harness.session.settle()
        #expect(harness.session.profile?.builtIn == .spelling)
        #expect(harness.local.streamInputs.count == 2)
    }

    // MARK: Direct apply (PRODUCT F2)

    private func directHarness(capture: Capture = SessionHarness.capture(), undoVerified: Bool = true,
                               accessibilityWrite: Bool = false, reply: String? = nil) throws -> SessionHarness {
        let harness = try SessionHarness(capture: capture)
        let testID = harness.test.id
        try harness.settings.update {
            $0.appDefaults[SessionHarness.app.bundleIdentifier!] = testID
            $0.directApplyApps = [SessionHarness.app.bundleIdentifier!]
        }
        harness.selection.strategyValue.undoVerified = undoVerified
        harness.selection.strategyValue.replaceViaAccessibilityWrite = accessibilityWrite
        if let reply { harness.local.reply = reply }
        return harness
    }

    @Test("direct apply on a clean result, an editable target and a paste strategy with undo verified")
    func directApplies() async throws {
        let harness = try directHarness()
        await harness.start()
        try await waitUntil { kind(harness.session.state) == "applied" }
        #expect(harness.selection.replaced.count == 1)
        #expect(!harness.effects.contains(.showPicker))
        #expect(harness.effects.contains(.toast(.replace(.replaced), profile: "Test", direct: true)))
    }

    @Test("anything else opens the picker with the reason", arguments: [
        ("flagged", DirectApplyDeclined.flagged),
        ("uncertain", .targetNotEditable),
        ("noUndo", .notUndoable),
        ("accessibilityWrite", .notUndoable),
    ])
    func directApplyDeclines(_ setup: String, _ reason: DirectApplyDeclined) async throws {
        let harness: SessionHarness = switch setup {
        case "flagged": try directHarness(reply: "Dear [Name], the meeting has moved to Friday.")
        case "uncertain": try directHarness(capture: SessionHarness.capture(editability: .uncertain))
        case "noUndo": try directHarness(undoVerified: false)
        default: try directHarness(accessibilityWrite: true)
        }
        await harness.start()
        try await waitUntil { harness.effects.contains(.showPicker) }
        #expect(harness.session.directApplyDeclined == reason)
        #expect(harness.selection.replaced.isEmpty)
    }

    @Test("the shortcut cancels a direct apply that is generating")
    func shortcutCancelsDirectApply() async throws {
        let harness = try directHarness()
        harness.local.hold = true
        await harness.session.start(.hotKey(app: SessionHarness.app, hotKeyCode: 15))
        try await waitUntil { if case .generating(let partial) = harness.session.state { !partial.isEmpty } else { false } }
        await harness.session.handle(.shortcut)
        await harness.session.settle()
        #expect(harness.session.state == .closed)
        #expect(harness.selection.replaced.isEmpty)
        #expect(!harness.effects.contains(.showPicker))
    }

    @Test("a capture refusal shows the picker even where direct apply is on")
    func refusalShowsPicker() async throws {
        let harness = try directHarness()
        harness.selection.captureResult = .failure(.passwordField)
        await harness.start()
        #expect(harness.session.state == .refusedCapture(.passwordField))
        #expect(harness.effects.contains(.showPicker))
        #expect(harness.streams == 0)
    }

    // MARK: Waiting for the clipboard (ARCHITECTURE §3.4)

    @Test("a copy during a timed-out read waits, then returns to where it was")
    func waitsForClipboard() async throws {
        let harness = try await Row.waitingForClipboard.reach()
        #expect(kind(harness.session.state) == "waitingForClipboard")
        #expect(harness.selection.copied.isEmpty)
        harness.selection.finishClipboardRead()
        try await waitUntil { kind(harness.session.state) == "ready" }

        let flagged = try await Row.flagged.reach()
        flagged.selection.copyAnswers = [false]
        Task { await flagged.session.handle(.commandC) }
        try await waitUntil { flagged.selection.isWaitingForClipboard }
        flagged.selection.finishClipboardRead()
        try await waitUntil { kind(flagged.session.state) == "flagged" }
    }

    @Test("a replace that finds the clipboard busy waits too")
    func replaceWaitsForClipboard() async throws {
        let harness = try await Row.readyEditable.reach()
        harness.selection.replaceOutcome = .clipboardBusy
        Task { await harness.session.handle(.returnKey) }
        try await waitUntil { harness.selection.isWaitingForClipboard }
        #expect(kind(harness.session.state) == "waitingForClipboard")
        harness.selection.finishClipboardRead()
        try await waitUntil { kind(harness.session.state) == "ready" }
    }

    // MARK: Correcting (⌘E)

    @Test("⌘Return commits the corrected text and the guards run again on it")
    func correctionCommits() async throws {
        let harness = try await Row.correcting.reach()
        harness.session.updateCorrection("The meeting moved to Friday, [Name].")
        await harness.press(.commandReturn)
        guard case .flagged(let text, let flags) = harness.session.state else { Issue.record("\(harness.session.state)"); return }
        #expect(text == "The meeting moved to Friday, [Name].")
        #expect(flags.contains { $0.guardID == "G2" })
        #expect(harness.sink.saved.isEmpty)
    }

    @Test("a formatting-loss flag stays after a correction")
    func formattingFlagStays() async throws {
        let harness = try SessionHarness(capture: SessionHarness.capture(formatting: .rich))
        await harness.start()
        guard case .flagged = harness.session.state else { Issue.record("\(harness.session.state)"); return }
        await harness.press(.commandE)
        harness.session.updateCorrection("The meeting is now on Friday.")
        await harness.press(.commandReturn)
        guard case .flagged(_, let flags) = harness.session.state else { Issue.record("\(harness.session.state)"); return }
        #expect(flags.contains(.formattingWillBeLost))
    }

    @Test("Save as example saves the pair to the profile")
    func savesExample() async throws {
        let harness = try await Row.correcting.reach()
        harness.session.updateCorrection("The meeting is on Friday now.")
        harness.session.setSaveAsExample(true)
        await harness.press(.commandReturn)
        #expect(harness.sink.saved.count == 1)
        #expect(harness.sink.saved.first?.example.output == "The meeting is on Friday now.")
        #expect(try harness.profiles.profile(harness.test.id)?.examples.count == 1)
    }

    @Test("over the 500-character cap, Save as example is disabled with the reason")
    func exampleCap() async throws {
        let long = String(repeating: "a", count: 501)
        let harness = try SessionHarness(capture: SessionHarness.capture(long))
        harness.local.reply = String(repeating: "b", count: 400)
        await harness.start()
        await harness.press(.commandE)
        harness.session.setSaveAsExample(true)
        guard case .correcting(let correction) = harness.session.state else { Issue.record("\(harness.session.state)"); return }
        #expect(correction.saveDisabledReason == .tooLong)
        #expect(!correction.saveAsExample)

        let short = try await Row.correcting.reach()
        short.session.setSaveAsExample(true)
        short.session.updateCorrection(String(repeating: "c", count: 501))
        guard case .correcting(let shortCorrection) = short.session.state else { Issue.record("\(short.session.state)"); return }
        #expect(shortCorrection.saveDisabledReason == .tooLong && !shortCorrection.saveAsExample)
    }

    @Test("with 8 examples, Quill asks which one the new example replaces")
    func fullProfileAsksWhichToReplace() async throws {
        let harness = try SessionHarness()
        var full = harness.test
        full.examples = (1...8).map { Example(input: "in \($0)", output: "Out \($0).") }
        _ = try harness.profiles.save(full)
        await harness.start()
        await harness.press(.commandE)
        harness.session.updateCorrection("The meeting is on Friday now.")
        harness.session.setSaveAsExample(true)
        await harness.press(.commandReturn)
        guard case .correcting(let correction) = harness.session.state,
              case .chooseReplacement(let offered) = correction.pending else { Issue.record("\(harness.session.state)"); return }
        #expect(offered.count == 8)
        harness.session.chooseExampleToReplace(offered[0].id)
        #expect(harness.sink.saved.first?.replacing == offered[0].id)
        #expect(kind(harness.session.state) == "ready")
        #expect(try harness.profiles.profile(full.id)?.examples.count == 8)
    }

    @Test("personal identifiers: neutral stand-ins, or save without the example")
    func personalIdentifiers() async throws {
        for useStandIns in [true, false] {
            let harness = try SessionHarness(capture: SessionHarness.capture("write to ana@example.org about friday"))
            harness.local.reply = "Write to ana@example.org about Friday."
            await harness.start()
            await harness.press(.commandE)
            harness.session.setSaveAsExample(true)
            await harness.press(.commandReturn)
            guard case .correcting(let correction) = harness.session.state,
                  case .personalData(let kinds) = correction.pending else { Issue.record("\(harness.session.state)"); continue }
            #expect(kinds.contains(.email))
            #expect(harness.sink.saved.isEmpty)
            harness.session.resolvePersonalData(useStandIns: useStandIns)
            #expect(harness.sink.saved.count == (useStandIns ? 1 : 0))
            #expect(harness.sink.neutralizedCount == (useStandIns ? 1 : 0))
            if useStandIns { #expect(harness.sink.saved.first?.example.input.contains("ana@") == false) }
            #expect(kind(harness.session.state) != "correcting")
        }
    }

    @Test("Esc in Correcting discards the edit")
    func correctingEscape() async throws {
        let harness = try await Row.correcting.reach()
        guard case .correcting(let correction) = harness.session.state, case .ready(let original) = correction.previous
        else { Issue.record("\(harness.session.state)"); return }
        harness.session.updateCorrection("Something else entirely.")
        await harness.press(.escape)
        #expect(harness.session.state == .ready(text: original))
    }
}

/// Against `Scripts/mock-chat-server.py` through the real Chat Completions adapter. Runs
/// only when `QUILL_MOCK_CHAT_URL` names a running server (`http://127.0.0.1:8765/v1`).
@Suite("Rewrite session against the mock server", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["QUILL_MOCK_CHAT_URL"] != nil))
@MainActor
struct RewriteSessionMockServerTests {
    @Test("the hosted path: consent, then a streamed rewrite, then a replace")
    func hostedPath() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["QUILL_MOCK_CHAT_URL"].flatMap(URL.init(string:)))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MockServerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = SettingsStore(dataDirectory: folder)
        let profiles = ProfileStore(dataDirectory: folder)
        try profiles.seedIfEmpty(language: "en")
        let server = CustomServer(id: "custom-mock", name: "Mock server", baseURL: url, requiresAPIKey: false)
        try settings.update {
            $0.customServers = [server]
            $0.globalModel = ModelSelection(provider: server.id, model: "mock")
        }
        let credentials = InMemoryCredentialStore()
        let holder = try ProviderRegistryHolder(
            shipped: [], customServers: try settings.settings().customServers,
            makeCustom: { $0.makeProvider(credentials: credentials) })
        let selection = FakeSelection(capture: SessionHarness.capture("see you on monday at the office"))
        let catalog = FakeCatalog()
        catalog.descriptors = [ModelSelection(provider: server.id, model: "mock"): ModelDescriptor(
            id: "mock", contextTokens: 32_768, pricing: ModelPricing(inputPerMillion: 1, outputPerMillion: 2))]
        let session = RewriteSession(
            settings: settings, profiles: profiles, registry: holder, engine: try GenerationEngine(),
            guards: try OutputGuards(), selection: selection, catalog: catalog,
            examples: FakeExampleSink(profiles: profiles), treatLoopbackAsRemote: true)
        await session.start(.hotKey(app: SessionHarness.app, hotKeyCode: 15))
        await session.settle()
        guard case .awaitingConsent(let notice) = session.state else { Issue.record("\(session.state)"); return }
        #expect(notice.provider == server.id)
        await session.handle(.returnKey)
        await session.settle()
        guard case .ready(let text) = session.state else { Issue.record("\(session.state)"); return }
        #expect(text.hasPrefix("S") && text.hasSuffix("."))
        await session.handle(.returnKey)
        #expect(selection.replaced.first?.text == text)
    }
}

/// ⌘E's store side (PLAN P4-T4): the live sink over the real profile store.
@Suite("Correct… saves into the profile store", .serialized)
@MainActor
struct CorrectionStoreTests {
    private func store() throws -> (ProfileStore, Profile, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CorrectionStoreTests-\(UUID().uuidString)")
        let store = ProfileStore(dataDirectory: folder)
        let profile = try store.save(Profile(name: "Work", symbol: "briefcase", settings: ProfileSettings(scope: .rewrite)))
        return (store, profile, folder)
    }

    @Test("saving a correction adds one example and one version")
    func addsExampleAndVersion() throws {
        let (store, profile, folder) = try store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sink = StoreExampleSink(profiles: store)
        let saved = try sink.save(Example(input: "see u monday", output: "See you on Monday."), to: profile.id, replacing: nil)
        #expect(saved.examples.count == 1)
        #expect(saved.version == profile.version + 1)
        #expect(try store.versions(of: profile.id).map(\.version) == [profile.version])
    }

    @Test("replacing at 8 examples keeps 8; the replaced one is gone")
    func replaces() throws {
        let (store, profile, folder) = try store()
        defer { try? FileManager.default.removeItem(at: folder) }
        var full = profile
        full.examples = (1...8).map { Example(input: "in \($0)", output: "Out \($0).") }
        let stored = try store.save(full)
        let sink = StoreExampleSink(profiles: store)
        let replaced = stored.examples[2].id
        let saved = try sink.save(Example(input: "new", output: "New."), to: profile.id, replacing: replaced)
        #expect(saved.examples.count == 8)
        #expect(!saved.examples.contains { $0.id == replaced })
    }

    @Test("stand-ins pass the identifier screen and keep the example's shape")
    func standIns() {
        let sink = StoreExampleSink(profiles: ProfileStore(dataDirectory: FileManager.default.temporaryDirectory))
        let neutral = sink.neutralized(Example(input: "call 612 345 678 or write ana@example.org",
                                               output: "Call 612 345 678 or write to ana@example.org."))
        #expect(PersonalDataScreen.isClean(neutral.input) && PersonalDataScreen.isClean(neutral.output))
        #expect(neutral.output.hasPrefix("Call ") && neutral.output.contains("write to"))
    }

    @Test("a correction committed in the session through the live sink is in the store")
    func throughTheSession() async throws {
        let harness = try SessionHarness()
        let live = StoreExampleSink(profiles: harness.profiles)
        let session = RewriteSession(
            settings: harness.settings, profiles: harness.profiles, registry: try ProviderRegistryHolder(
                shipped: [harness.local], customServers: [], makeCustom: { _ in fatalError() }),
            engine: try GenerationEngine(), guards: try OutputGuards(), selection: harness.selection,
            catalog: harness.catalog, examples: live)
        await session.start(.hotKey(app: SessionHarness.app, hotKeyCode: 15))
        await session.settle()
        await session.handle(.commandE)
        session.updateCorrection("The meeting is on Friday now.")
        session.setSaveAsExample(true)
        await session.handle(.commandReturn)
        let stored = try #require(try harness.profiles.profile(harness.test.id))
        #expect(stored.examples.map(\.output) == ["The meeting is on Friday now."])
        #expect(stored.version == harness.test.version + 1)
        #expect(session.profile?.examples.count == 1, "the next rerun sends it")
    }

    // MARK: Instruction and pointer (PRODUCT §4.1)

    @Test("Return sends a typed instruction; the rewrite carries it and keeps the safety rules")
    func instruction() async throws {
        let harness = try SessionHarness()
        await harness.start()
        let before = harness.local.streamInstructions.count
        harness.session.instructionDraft = "make it shorter"
        #expect(harness.session.instructionPending)
        await harness.session.pressReturn()
        await harness.session.settle()
        #expect(harness.local.streamInstructions.count == before + 1, "Return sent the instruction, it did not apply")
        #expect(harness.selection.replaced.isEmpty)
        let instructions = try #require(harness.local.streamInstructions.last)
        #expect(instructions.hasSuffix("make it shorter"))
        #expect(harness.session.activeInstruction == "make it shorter")
        #expect(harness.session.profile?.id == RewriteSession.instructionProfileID)
        #expect(!harness.session.instructionPending, "the result was made with it: the next Return applies")
        guard case .ready = harness.session.state else { Issue.record("not ready: \(harness.session.state)"); return }
        await harness.session.pressReturn()
        await harness.session.settle()
        #expect(!harness.selection.replaced.isEmpty, "Return now applies the instruction's result")
    }

    @Test("an instruction is never remembered as the last used profile")
    func instructionNotLastUsed() async throws {
        let harness = try SessionHarness()
        await harness.start()
        harness.session.instructionDraft = "more formal"
        await harness.session.submitInstruction()
        await harness.session.settle()
        #expect(try harness.settings.settings().lastUsedProfile == harness.test.id)
    }

    @Test("choosing a profile drops the instruction; a click is the same as its number")
    func profileAfterInstruction() async throws {
        let harness = try SessionHarness()
        await harness.start()
        harness.session.instructionDraft = "as a list"
        await harness.session.submitInstruction()
        await harness.session.settle()
        await harness.session.selectProfile(at: 0)
        await harness.session.settle()
        #expect(harness.session.activeInstruction == nil)
        #expect(harness.session.instructionDraft.isEmpty)
        #expect(harness.session.profile?.id == harness.session.profileList.first?.id)
        let instructions = try #require(harness.local.streamInstructions.last)
        #expect(!instructions.contains("as a list"))
    }

    @Test("a blank draft is not an instruction: Return keeps its state's meaning")
    func blankInstruction() async throws {
        let harness = try SessionHarness()
        await harness.start()
        harness.session.instructionDraft = "   "
        #expect(!harness.session.instructionPending)
        await harness.session.pressReturn()
        await harness.session.settle()
        #expect(!harness.selection.replaced.isEmpty, "Return applied the profile's result")
    }
}
