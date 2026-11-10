import AppKit
import Foundation
import Observation
import QuillSupport
import SelectionKit
import VoiceKit

/// Where dictated words go: the app in front and the place its cursor was when the
/// shortcut went down, read then — by the time the words are ready the user may have
/// clicked elsewhere, and the field has nothing selected to compare against.
struct DictationTarget: Equatable, Sendable {
    var app: AppIdentity
    var element: AccessibilityElement?
    var range: CFRange?
    /// What the field had selected: dictation replaces it, as typing would.
    var selected: String
    var editability: Editability
    /// The cursor, in Cocoa screen coordinates, when the app reports it.
    var caret: CGRect?
    /// The text field's frame, for apps that report the field but not its cursor (web
    /// views, Electron apps such as Claude or Slack).
    var field: CGRect?

    /// Where the picker opens: the cursor, or the top of the field's leading edge.
    var anchor: CGRect? {
        caret ?? field.map { CGRect(x: $0.minX + 12, y: $0.maxY - 1, width: 1, height: 1) }
    }

    /// Where the capsule goes.
    var placement: DictationAnchor {
        if let caret { return .caret(caret) }
        if let field { return .field(field) }
        return .none
    }

    static func == (lhs: DictationTarget, rhs: DictationTarget) -> Bool {
        lhs.app == rhs.app && lhs.element == rhs.element && lhs.selected == rhs.selected
            && lhs.editability == rhs.editability && lhs.caret == rhs.caret && lhs.field == rhs.field
            && lhs.range?.location == rhs.range?.location && lhs.range?.length == rhs.range?.length
    }

    /// The capture the picker rewrites: the words said, to be written over what the field
    /// had selected. Nothing to lose in formatting: the words are new.
    func capture(of text: String) -> Capture {
        Capture(text: text, app: app, element: element, range: range, editability: editability,
                formatting: .plain, bounds: anchor, method: .accessibility, fieldSelection: selected)
    }

    /// Reads the focused field of `app`: its selection, whether it takes text, its cursor.
    static func locate(app: AppIdentity, operations: SelectionOperations, primaryScreenHeight: CGFloat) -> DictationTarget {
        guard case .success(let focused) = operations.focusedElement() else {
            return DictationTarget(app: app, selected: "", editability: .uncertain)
        }
        let read = operations.readSelection(of: focused.element)
        if read.isSecureField { return DictationTarget(app: app, selected: "", editability: .readOnlyOnly) }
        let strategy = AppStrategy.strategy(for: app.bundleIdentifier)
        let editability: Editability = strategy.readOnlyOnly || read.isTerminalHelper ? .readOnlyOnly
            : read.selectedTextSettable == true || read.valueSettable == true ? .editable : .uncertain
        var caret = read.range.flatMap {
            operations.selectionBounds(of: focused.element, range: $0, primaryScreenHeight: primaryScreenHeight)
        }
        // An empty selection has no width in some apps and no rectangle in others: the
        // character before the cursor stands in for it.
        if caret == nil || caret?.height == 0, let range = read.range, range.location > 0 {
            caret = operations.selectionBounds(of: focused.element, range: CFRange(location: range.location - 1, length: 1),
                                               primaryScreenHeight: primaryScreenHeight)
                .map { CGRect(x: $0.maxX, y: $0.minY, width: 1, height: $0.height) }
        }
        return DictationTarget(app: app, element: focused.element, range: read.range, selected: read.text ?? "",
                               editability: editability, caret: caret.flatMap { $0.height > 0 ? $0 : nil },
                               field: operations.frame(of: focused.element, primaryScreenHeight: primaryScreenHeight))
    }
}

/// Dictate and rewrite (EFFICIENCY.md E8; J-17, J-19): holding the rewrite shortcut loads
/// the model and, past the threshold, opens the microphone; the words show as they are
/// said, beside the cursor, and go on after the keys are let go; pressing the shortcut
/// again sends what was said through the profile picker to that cursor.
///
/// The engine is Ámbar's (`VoiceKit`), in Quill's own process: it works whether Ámbar
/// is installed or not. When it is, Ámbar's dictation dictionary — the words the user
/// taught it — biases the engine and corrects the text, so a word taught once is
/// written right in both apps.
@MainActor
@Observable
final class DictationRewrite {
    enum Phase: Equatable {
        case idle
        /// The keys are down: the model loads, the microphone stays closed, nothing shows.
        case armed
        case listening
        /// The words are being finished.
        case finishing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// What was said so far, corrected with the dictionary.
    private(set) var text = ""
    /// How many characters at the end of `text` the engine may still change.
    private(set) var volatileCharacters = 0
    /// Ámbar's dictionary was found and is in use.
    private(set) var usesAmbarDictionary = false
    /// The voice's loudness, 0…1, rising at once and falling slowly.
    private(set) var level: Float = 0
    /// Where the words go, read when the shortcut went down.
    private(set) var target: DictationTarget?

    /// Receives what was said and where it goes.
    @ObservationIgnored var deliver: (String, DictationTarget) -> Void = { _, _ in }
    /// Shows (true) or hides the panel.
    @ObservationIgnored var showPanel: (Bool) -> Void = { _ in }
    /// The dictation ended without delivering (cancelled, failed): the shortcut resets.
    @ObservationIgnored var onEnded: () -> Void = {}

    /// Makes a session for the given contextual strings: the microphone in the app, a
    /// file in tests and in the debug hook.
    private let makeSession: ([String]) -> any TranscriptionSession
    /// Ámbar's `dictionary.json`, when Ámbar is installed.
    private let dictionaryFile: () -> URL?
    private var session: (any TranscriptionSession)?
    private var preparing: Task<Bool, Never>?
    private var rules: [VocabularyCorrector.Rule] = []
    private var stream: Task<Void, Never>?
    private var levelDecay: Task<Void, Never>?
    private let log = QuillLog(category: "dictation")

    /// How long the last words may take to settle after the user is done.
    static let finishCeiling: Duration = .seconds(4)

    init(makeSession: @escaping ([String]) -> any TranscriptionSession,
         dictionaryFile: @escaping () -> URL? = DictationRewrite.ambarDictionary) {
        self.makeSession = makeSession
        self.dictionaryFile = dictionaryFile
    }

    var isActive: Bool {
        switch phase {
        case .armed, .listening, .finishing: true
        case .idle, .failed: false
        }
    }

    // MARK: The gesture

    /// The keys went down over `target`: the model loads while the user decides whether
    /// this is a tap or a hold. Costs milliseconds once the model is resident; the
    /// microphone stays closed.
    func arm(for target: DictationTarget) {
        guard !isActive else { return }
        self.target = target
        text = ""
        volatileCharacters = 0
        level = 0
        let entries = dictionaryFile().map(DictationDictionary.load(from:)) ?? []
        usesAmbarDictionary = !entries.isEmpty
        rules = DictationDictionary.replacementRules(entries)
        let session = makeSession(DictationDictionary.contextualStrings(entries))
        self.session = session
        phase = .armed
        preparing = Task { [weak self] in
            do {
                try await session.prepare()
                return true
            } catch {
                self?.fail(error)
                return false
            }
        }
    }

    /// A tap after all: let the model go, quietly.
    func disarm() async {
        guard phase == .armed else { return }
        let session = self.session
        reset()
        await session?.cancel()
    }

    /// The hold passed its threshold: open the microphone and show the panel.
    func startListening() async {
        guard phase == .armed, let session else { return }
        showPanel(true)
        guard await preparing?.value == true, phase == .armed else { return }
        if let speech = session as? SpeechSession {
            await speech.setLevelHandler { [weak self] value in
                Task { @MainActor in self?.hear(value) }
            }
        }
        do {
            let fragments = try await session.start()
            guard phase == .armed else {
                await session.cancel()
                return
            }
            phase = .listening
            let rules = self.rules
            stream = Task { [weak self] in
                for await fragment in fragments {
                    let corrected = VocabularyCorrector.apply(rules, to: fragment.text).text
                    self?.text = corrected
                    self?.volatileCharacters = min(fragment.volatileCharacterCount, corrected.count)
                }
            }
            levelDecay = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard let self else { return }
                    self.level *= 0.86
                }
            }
        } catch {
            fail(error)
        }
    }

    /// Done talking: finish the words and hand them to the rewrite.
    func finish() async {
        guard phase == .listening || phase == .armed, let session, let target else { return }
        phase = .finishing
        let outcome = await Self.withCeiling(Self.finishCeiling) { try await session.finish() }
        stream?.cancel()
        stream = nil
        let said: String
        switch outcome {
        case .success(let transcript): said = transcript.text
        case .failure(let error):
            // The ceiling passed or the engine failed: what was shown is what was heard.
            log.error("dictation finish: \(error)")
            said = text
        }
        let corrected = VocabularyCorrector.apply(rules, to: said).text.trimmingCharacters(in: .whitespacesAndNewlines)
        reset()
        showPanel(false)
        guard !corrected.isEmpty else {
            onEnded()
            return
        }
        deliver(corrected, target)
    }

    /// Stops without delivering anything.
    func cancel() async {
        let session = self.session
        reset()
        showPanel(false)
        onEnded()
        await session?.cancel()
    }

    /// The menu's "Dictate and Rewrite": listening at once, hands-free, until it is chosen
    /// again or the shortcut is pressed.
    func toggle(target: @autoclosure () -> DictationTarget?) async {
        switch phase {
        case .idle, .failed:
            guard let target = target() else { return }
            arm(for: target)
            await startListening()
        case .listening, .armed:
            await finish()
        case .finishing:
            break
        }
    }

    /// Closes the panel of a failure.
    func dismissFailure() {
        guard case .failed = phase else { return }
        phase = .idle
        showPanel(false)
    }

    // MARK: Internals

    private func hear(_ value: Float) {
        guard phase == .listening else { return }
        level = max(level, value)
    }

    private func fail(_ error: Error) {
        guard !(error is CancellationError) else { return }
        log.error("dictation failed: \(error)")
        let message: String = switch error as? DictationEngineError {
        case .modelNotInstalled?, .localeUnsupported?: PickerCopy.string("dictation.error.model")
        case .noInputDevice?, .audioEngineFailed?, .incompatibleAudioFormat?: PickerCopy.string("dictation.error.microphone")
        case .reservationQuotaExceeded?: PickerCopy.string("dictation.error.busy")
        default: PickerCopy.string("dictation.error.other")
        }
        let session = self.session
        stream?.cancel()
        stream = nil
        levelDecay?.cancel()
        levelDecay = nil
        self.session = nil
        phase = .failed(message)
        showPanel(true)
        onEnded()
        Task { await session?.cancel() }
    }

    private func reset() {
        stream?.cancel()
        stream = nil
        levelDecay?.cancel()
        levelDecay = nil
        preparing = nil
        session = nil
        level = 0
        phase = .idle
    }

    static func withCeiling<T: Sendable>(_ ceiling: Duration, _ work: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
        await withTaskGroup(of: Result<T, Error>?.self) { group in
            group.addTask {
                do { return .success(try await work()) } catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(for: ceiling)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(CancellationError())
        }
    }

    /// `~/Library/Application Support/Ambar/dictionary.json`, when Ámbar wrote one.
    nonisolated static func ambarDictionary() -> URL? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Ambar", directoryHint: .isDirectory)
            .appending(path: DictationDictionary.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
