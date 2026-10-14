import AppKit
import ListenKit
import MeetingKit
import ModelKit
import Observation
import QuillSupport
import SpeakerKit
import SynthesisKit
import Translation

/// Meetings, end to end (MEETINGS.md §6): notices a meeting app opening the microphone,
/// offers to listen, listens, tells the voices apart, and hands the meeting to the
/// window where people get names and roles and the meeting gets synthesised.
@MainActor
@Observable
final class MeetingsCoordinator {
    enum Phase: Equatable {
        case idle
        case offering(MeetingApp)
        case listening(MeetingApp)
        /// The meeting ended; voices are being told apart.
        case separating
    }

    private(set) var phase: Phase = .idle
    /// A finished segment in the live panel, with its translation once it arrives.
    struct LiveLine: Identifiable, Equatable {
        let id: Int
        let segment: TranscriptSegment
        var translation: String?
        /// The voice it belongs to, once a live diarization pass has heard it.
        var speaker: String?
    }

    /// A voice told apart during the meeting, named by the user as it goes.
    struct LiveVoice: Identifiable, Equatable {
        var id: String { label }
        let label: String
        var name: String
        var roleID: String?
        var seconds: Double
    }

    /// Live translation (macOS's on-device Translation framework): off when the meeting
    /// is in the user's language, waiting for the language pack when it is not on the
    /// Mac yet, or on.
    enum TranslationState: Equatable {
        case off
        case needsDownload(TranslationSession.Configuration)
        case active(target: String)
        case unavailable
    }

    /// The last finished segments, for the live panel.
    private(set) var liveLines: [LiveLine] = []
    private var nextLineID = 0
    private(set) var translationState: TranslationState = .off
    private var translator: TranslationSession?
    /// Voices heard so far, in order of first appearance.
    private(set) var liveVoices: [LiveVoice] = []
    private var labeler = SpeakerLabeler()
    private var liveSeparator: SpeakerSeparator?
    private var diarizationLoop: Task<Void, Never>?
    private var diarizationPass: Task<Void, Never>?
    /// Lines wait here and are translated one at a time, in order: a session is not
    /// meant to be used from several tasks at once.
    private var translationQueue: AsyncStream<LiveLine>.Continuation?
    private var translationWorker: Task<Void, Never>?
    private(set) var listeningSince: Date?
    private(set) var lastError: String?
    /// A meeting being set up from the offer: its language may need downloading first.
    private(set) var preparing: String? { didSet { refitOffer() } }
    /// Why the last start from the offer failed, said in the offer itself.
    private(set) var offerError: String? { didSet { refitOffer() } }

    private func refitOffer() {
        Task { @MainActor [weak self] in self?.offerPanel?.refit() }
    }
    /// Channels whose capture stopped delivering and is being rebuilt: the live panel
    /// says so, instead of the meeting quietly losing a side.
    private(set) var lostChannels: Set<Channel> = []
    var preferences: MeetingPreferences

    let store: MeetingStore
    let environment: AppEnvironment
    private var monitor: AudioActivityMonitor?
    private var session: ListenSession?
    /// Apps already offered for their current microphone use: "Ahora no" is not asked
    /// again until the app closes the microphone and opens it again.
    private var declined: Set<String> = []
    private let log = QuillLog(category: "meetings")

    private var offerPanel: MeetingPanelController<OfferView>?
    private var livePanel: LivePanelController?
    private var meetingWindows: [UUID: MeetingWindowController] = [:]
    private(set) var history: MeetingHistoryController?
    private var focusEditor: FocusEditorController?

    init(environment: AppEnvironment) throws {
        self.environment = environment
        let directory = environment.dataDirectory.appendingPathComponent("meetings-data", isDirectory: true)
        store = try MeetingStore(directory: directory)
        preferences = MeetingPreferences.load(from: directory)
    }

    var directory: URL { store.directory }

    func start() {
        do {
            let removed = try store.purge(olderThan: preferences.retentionDays)
            if removed > 0 { log.info("retention removed \(removed) meetings") }
        } catch {
            log.error("retention purge failed: \(error)")
        }
        let monitor = AudioActivityMonitor { [weak self] processes in
            MainActor.assumeIsolated { self?.microphoneUseChanged(processes) }
        }
        monitor.start()
        self.monitor = monitor
    }

    func savePreferences() {
        do {
            try preferences.save(to: directory)
        } catch {
            log.error("could not save meeting preferences: \(error)")
        }
    }

    // MARK: Offer

    private func microphoneUseChanged(_ processes: [AudioProcess]) {
        let apps = MeetingApp.known.filter { preferences.offerApps.contains($0.id) }
        let recording = MeetingApp.recording(among: apps, processes: processes)
        let recordingIDs = Set(recording.map(\.id))
        declined.formIntersection(recordingIDs)

        switch phase {
        case .idle:
            guard let app = recording.first(where: { !declined.contains($0.id) }) else { return }
            if preferences.autoStartApps.contains(app.id) {
                Task { await startListening(to: app) }
            } else {
                offer(app)
            }
        case .offering(let app):
            if !recordingIDs.contains(app.id) { dismissOffer() }
        case .listening, .separating:
            break
        }
    }

    func offer(_ app: MeetingApp) {
        phase = .offering(app)
        offerError = nil
        preparing = nil
        let view = OfferView(coordinator: self, app: app,
                             accept: { [weak self] language in Task { await self?.startListening(to: app, language: language) } },
                             decline: { [weak self] in self?.decline(app) })
        offerPanel?.close()
        let panel = MeetingPanelController(content: view, placement: .topTrailing, activates: false)
        panel.show()
        offerPanel = panel
    }

    func decline(_ app: MeetingApp) {
        declined.insert(app.id)
        dismissOffer()
    }

    private func dismissOffer() {
        offerPanel?.close()
        offerPanel = nil
        if case .offering = phase { phase = .idle }
    }

    /// The menu's "Transcribe a meeting": the offer for the app using the microphone now,
    /// or the first meeting app with a running process — so the language can be chosen
    /// there too.
    func startFromMenu() {
        Task {
            let processes = (try? AudioProcesses.all()) ?? []
            let app = MeetingApp.recording(among: MeetingApp.known, processes: processes).first
                ?? MeetingApp.known.first { app in processes.contains { $0.bundleID.map(app.matches) ?? false } }
            guard let app else {
                lastError = MeetingCopy.t("meetings.error.noApp")
                NSSound.beep()
                return
            }
            offer(app)
        }
    }

    // MARK: Listening

    /// - Parameter language: this meeting's language; nil is the one in Settings.
    func startListening(to app: MeetingApp, language: String? = nil) async {
        guard session == nil, preparing == nil else { return }
        let language = language ?? preferences.localeIdentifier
        // The offer stays up, saying so, while the language is prepared: the first time
        // a language is used its model is downloaded, and that takes a while.
        preparing = MeetingPreferences.languageName(language)
        offerError = nil
        defer { preparing = nil }
        // The exact bundle IDs of the app's processes now, tapped by ID so helpers that
        // restart mid-call are picked up again (macOS 26 `processRestoreEnabled`).
        let processes = (try? AudioProcesses.all()) ?? []
        let bundleIDs = Array(Set(processes.compactMap(\.bundleID).filter(app.matches)))
        guard !bundleIDs.isEmpty else {
            lastError = MeetingCopy.t("meetings.error.noAudio")
            offerError = lastError
            return
        }
        let session = ListenSession(configuration: .init(
            target: .bundleIDs(bundleIDs),
            sourceName: app.name,
            locale: Locale(identifier: language),
            includeMicrophone: preferences.includeMicrophone,
            keepsOthersAudio: preferences.separateSpeakers
        ))
        do {
            try await session.start(onSegment: { [weak self] segment in
                Task { @MainActor in self?.append(segment) }
            }, onHealth: { [weak self] channel, healthy in
                Task { @MainActor in self?.channelHealthChanged(channel, healthy: healthy) }
            })
        } catch {
            lastError = Self.describe(error, language: language)
            offerError = lastError
            log.error("listening failed to start: \(error)")
            return
        }
        dismissOffer()
        self.session = session
        liveLines = []
        lostChannels = []
        await setUpTranslation(language: language)
        startLiveDiarization()
        listeningSince = Date()
        lastError = nil
        phase = .listening(app)
        if preferences.showsLivePanel { showLivePanel(app: app) }
    }

    private func channelHealthChanged(_ channel: Channel, healthy: Bool) {
        guard case .listening(let app) = phase else { return }
        if healthy {
            lostChannels.remove(channel)
            log.info("capture of \(channel.rawValue) recovered")
        } else {
            lostChannels.insert(channel)
            log.error("capture of \(channel.rawValue) stopped delivering; rebuilding")
            // A hidden panel cannot warn: bring it back, without taking focus.
            if livePanel == nil { showLivePanel(app: app) }
        }
    }

    private func append(_ segment: TranscriptSegment) {
        let line = LiveLine(id: nextLineID, segment: segment)
        nextLineID += 1
        liveLines.append(line)
        if liveLines.count > 80 { liveLines.removeFirst(liveLines.count - 80) }
        translate(line)
    }

    /// How loud each side is now, for the recording orb.
    var levels: (others: Float, me: Float) { session?.levels ?? (0, 0) }

    /// A start failure in the user's words, not the framework's.
    static func describe(_ error: Error, language: String) -> String {
        let name = MeetingPreferences.languageName(language)
        switch error as? ListenError {
        case .modelNotInstalled?:
            return String(localized: "meetings.error.model \(name)", bundle: .localized)
        case .localeUnsupported?:
            return String(localized: "meetings.error.language \(name)", bundle: .localized)
        case .microphoneUnavailable?:
            return MeetingCopy.t("meetings.error.microphone")
        default:
            return String(localized: "meetings.error.start \(String(describing: error))", bundle: .localized)
        }
    }

    // MARK: Live voices

    /// Every two minutes, the others' audio so far is separated again, in the
    /// background, and its voices labelled to continue the previous pass
    /// (`SpeakerLabeler`). Measured on the bench (TESTING-MEETINGS.md): a name given in
    /// the first minutes points at the right person for 75–80 % of the speech, about
    /// 90 % from minute eight; a voice close to another may only appear later.
    private func startLiveDiarization() {
        liveVoices = []
        labeler = SpeakerLabeler()
        guard preferences.separateSpeakers else { return }
        let separator = SpeakerSeparator(modelsDirectory: directory.appendingPathComponent("models", isDirectory: true))
        liveSeparator = separator
        diarizationLoop = Task { @MainActor [weak self] in
            try? await separator.prepare()
            var interval: Duration = .seconds(60)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                interval = .seconds(120)
                guard let self, !Task.isCancelled else { return }
                await self.runDiarizationPass(separator)
            }
        }
    }

    private func runDiarizationPass(_ separator: SpeakerSeparator) async {
        guard let session, diarizationPass == nil else { return }
        let samples = session.othersAudioSoFar()
        guard Double(samples.count) / AudioAccumulator.sampleRate > 20 else { return }
        let pass = Task.detached(priority: .utility) { () -> [SpeakerTurn]? in
            try? SpeakerTurn.absorbingMinorVoices(await separator.turns(for: samples))
        }
        diarizationPass = Task { _ = await pass.value }
        defer { diarizationPass = nil }
        guard let turns = await pass.value, self.session != nil else { return }
        let labelled = labeler.label(turns)
        applyLiveLabels(labelled)
    }

    private func applyLiveLabels(_ turns: [SpeakerTurn]) {
        var seconds: [String: Double] = [:]
        for turn in turns { seconds[turn.speaker, default: 0] += turn.end - turn.start }
        var order: [String] = liveVoices.map(\.label).filter { seconds[$0] != nil }
        for turn in turns.sorted(by: { $0.start < $1.start }) where !order.contains(turn.speaker) {
            order.append(turn.speaker)
        }
        let previous = Dictionary(uniqueKeysWithValues: liveVoices.map { ($0.label, $0) })
        liveVoices = order.map { label in
            var voice = previous[label] ?? LiveVoice(label: label, name: "", roleID: nil, seconds: 0)
            voice.seconds = seconds[label] ?? 0
            return voice
        }
        for index in liveLines.indices where liveLines[index].segment.channel == .others {
            let segment = liveLines[index].segment
            liveLines[index].speaker = labeler.speaker(from: segment.start, to: segment.end)
        }
    }

    func nameLiveVoice(_ label: String, name: String, roleID: String?) {
        guard let index = liveVoices.firstIndex(where: { $0.label == label }) else { return }
        liveVoices[index].name = name.trimmingCharacters(in: .whitespaces)
        liveVoices[index].roleID = roleID
    }

    /// What the live panel calls a voice: its name, else "Persona N".
    func liveName(_ label: String) -> String {
        if let voice = liveVoices.first(where: { $0.label == label }), !voice.name.isEmpty { return voice.name }
        let number = label.split(separator: "-").last.map(String.init) ?? label
        return String(localized: "label.person \(number)", bundle: .localized)
    }

    var roles: [MeetingRole] { store.roles() }

    private func stopLiveDiarization() async {
        diarizationLoop?.cancel()
        diarizationLoop = nil
        await diarizationPass?.value
        liveSeparator = nil
    }

    // MARK: Translation

    /// Chooses the translation state for the meeting that just started.
    private func setUpTranslation(language: String) async {
        stopTranslation()
        guard preferences.needsTranslation(for: language) else {
            translationState = .off
            return
        }
        let source = Locale(identifier: language).language
        let target = preferences.translationLanguage
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            startTranslator(source: source, target: target)
        case .supported:
            translationState = .needsDownload(TranslationSession.Configuration(source: source, target: target))
        default:
            translationState = .unavailable
            log.info("no translation from \(source.minimalIdentifier) to \(target.minimalIdentifier)")
        }
    }

    private func startTranslator(source: Locale.Language, target: Locale.Language) {
        let translator = TranslationSession(installedSource: source, target: target)
        self.translator = translator
        let (stream, continuation) = AsyncStream<LiveLine>.makeStream()
        translationQueue = continuation
        translationWorker?.cancel()
        translationWorker = Task { @MainActor [weak self] in
            for await line in stream {
                do {
                    let response = try await translator.translate(line.segment.text)
                    guard let self, let index = self.liveLines.firstIndex(where: { $0.id == line.id }) else { continue }
                    self.liveLines[index].translation = response.targetText
                } catch {
                    self?.log.error("translation failed: \(error)")
                }
            }
        }
        translationState = .active(target: Locale.current.localizedString(forLanguageCode: target.languageCode?.identifier ?? "") ?? target.minimalIdentifier)
        // What was said before the pack was ready gets translated too.
        for line in liveLines where line.translation == nil { translate(line) }
    }

    /// The language pack finished downloading (the live panel's `.translationTask`).
    func translationDownloaded() {
        guard case .needsDownload(let configuration) = translationState,
              let source = configuration.source, let target = configuration.target else { return }
        startTranslator(source: source, target: target)
    }

    /// The others' words, into the user's language. The user's own are already theirs.
    private func translate(_ line: LiveLine) {
        guard translator != nil, line.segment.channel == .others else { return }
        translationQueue?.yield(line)
    }

    private func stopTranslation() {
        translationQueue?.finish()
        translationQueue = nil
        translationWorker?.cancel()
        translationWorker = nil
        translator = nil
        translationState = .off
    }

    func showLivePanel(app: MeetingApp) {
        livePanel?.close()
        let panel = LivePanelController(coordinator: self, app: app)
        panel.show()
        livePanel = panel
    }

    func hideLivePanel() {
        livePanel?.close()
        livePanel = nil
    }

    var isListening: Bool {
        if case .listening = phase { return true }
        return false
    }

    /// Stops listening, tells the voices apart and opens the meeting.
    func finish() async {
        guard let session, case .listening(let app) = phase else { return }
        hideLivePanel()
        let started = listeningSince ?? Date()
        phase = .separating
        let captured = session.secondsCaptured
        var transcript = await session.stop()
        log.info("capture: \(session.diagnostics.joined(separator: " | "))")
        lostChannels = []
        let samples = session.takeOthersAudio()
        await stopLiveDiarization()
        self.session = nil

        var people: [String: UUID] = [:]
        if preferences.separateSpeakers, !samples.isEmpty, transcript.segments.contains(where: { $0.channel == .others }) {
            let separator = SpeakerSeparator(modelsDirectory: directory.appendingPathComponent("models", isDirectory: true))
            do {
                try await separator.prepare()
                // Voices that barely speak are interruptions heard as a new person (TESTING-MEETINGS.md).
                // Labelled to continue the live passes, so names given during the meeting stay.
                let turns = labeler.label(SpeakerTurn.absorbingMinorVoices(try await separator.turns(for: samples)))
                transcript = transcript.assigningSpeakers(turns, renumbering: false)
                for voice in liveVoices where !voice.name.isEmpty && transcript.segments.contains(where: { $0.speaker == voice.label }) {
                    transcript.names[voice.label] = voice.name
                    if let person = try? store.remember(name: voice.name, roleID: voice.roleID, at: started) {
                        people[voice.label] = person.id
                    }
                }
            } catch {
                log.error("diarization failed: \(error)")
                lastError = MeetingCopy.t("meetings.error.separation")
            }
        }

        let record = MeetingRecord(
            title: String(localized: "meetings.defaultTitle \(app.name)", bundle: .localized),
            sourceApp: app.name,
            startedAt: started,
            duration: Date().timeIntervalSince(started),
            transcript: transcript,
            people: people,
            capturedSeconds: Dictionary(uniqueKeysWithValues: captured.map { ($0.key.rawValue, $0.value) })
        )
        for channel in record.silentChannels {
            log.error("meeting saved with little audio from \(channel.rawValue): \(captured[channel] ?? 0) s of \(record.duration) s")
        }
        do {
            try store.save(record)
        } catch {
            log.error("could not save the meeting: \(error)")
        }
        phase = .idle
        listeningSince = nil
        liveLines = []
        liveVoices = []
        stopTranslation()
        openMeeting(record.id, step: .people)
    }

    /// Stops without keeping anything.
    func discard() async {
        guard let session else { return }
        hideLivePanel()
        await stopLiveDiarization()
        liveVoices = []
        _ = await session.stop()
        _ = session.takeOthersAudio()
        self.session = nil
        phase = .idle
        listeningSince = nil
        liveLines = []
        stopTranslation()
    }

    #if DEBUG
    /// Snapshot support: the live panel with given segments, without listening.
    func debugShowLive(app: MeetingApp, segments: [TranscriptSegment]) {
        phase = .listening(app)
        listeningSince = Date().addingTimeInterval(-768)
        liveLines = segments.enumerated().map { LiveLine(id: $0.offset, segment: $0.element) }
        showLivePanel(app: app)
    }

    func debugStopMonitor() {
        monitor?.stop()
        monitor = nil
    }

    func debugReset() {
        hideLivePanel()
        dismissOffer()
        phase = .idle
    }

    var debugOfferWindow: NSWindow? { offerPanel?.window }
    var debugLiveWindow: NSWindow? { livePanel?.window }
    func debugCollapseLive() { livePanel?.collapse() }
    /// Voices as a live pass would leave them: label per line, and names for some.
    func debugLiveVoices(names: [String: String], roles: [String: String]) {
        var labels: [String] = []
        for index in liveLines.indices where liveLines[index].segment.channel == .others {
            let label = "speaker-\(index % 3 + 1)"
            liveLines[index].speaker = label
            if !labels.contains(label) { labels.append(label) }
        }
        liveVoices = labels.map { LiveVoice(label: $0, name: names[$0] ?? "", roleID: roles[$0], seconds: 30) }
    }
    func debugTranslate(_ translations: [String]) {
        for (index, text) in translations.enumerated() where liveLines.indices.contains(index) {
            liveLines[index].translation = text
        }
        translationState = .active(target: "español")
    }
    func debugMeetingWindow(_ id: UUID) -> NSWindow? { meetingWindows[id]?.shownWindow }
    func debugMeetingModel(_ id: UUID) -> MeetingFlowModel? { meetingWindows[id]?.debugModel }
    var debugFocusEditorWindow: NSWindow? { focusEditor?.shownWindow }
    #endif

    // MARK: Windows

    func openMeeting(_ id: UUID, step: MeetingFlowModel.Step) {
        guard let record = store.meeting(id) else { return }
        if let window = meetingWindows[id] {
            window.show(step: step)
            return
        }
        let model = MeetingFlowModel(record: record, coordinator: self, step: step)
        let controller = MeetingWindowController(model: model)
        controller.onClose = { [weak self] in self?.meetingWindows[id] = nil }
        meetingWindows[id] = controller
        controller.show(step: step)
    }

    func openHistory() {
        if history == nil { history = MeetingHistoryController(coordinator: self) }
        history?.show()
    }

    func openFocusEditor() {
        if focusEditor == nil {
            focusEditor = FocusEditorController(store: store) { [weak self] in self?.focusesChanged() }
        }
        focusEditor?.show()
    }

    private func focusesChanged() {
        for window in meetingWindows.values { window.reloadFocuses() }
    }

    /// A meeting changed (names, a new synthesis): refresh the history if it is open.
    func meetingChanged() {
        history?.reload()
    }
}

// The Translation framework's session is used only from the main actor here (the
// coordinator's serial queue and the live panel's download task), never concurrently.
extension TranslationSession: @retroactive @unchecked Sendable {}
