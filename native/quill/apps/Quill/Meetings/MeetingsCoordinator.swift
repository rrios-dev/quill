import AppKit
import ListenKit
import MeetingKit
import ModelKit
import Observation
import QuillAgent
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
        /// The segment's text with the vocabulary of whoever said it, as far as the live
        /// panel knows who that is (EFFICIENCY.md E5).
        var text: String
    }

    /// A voice told apart during the meeting, named by the user as it goes.
    struct LiveVoice: Identifiable, Equatable {
        var id: String { label }
        let label: String
        var name: String
        var roleID: String?
        var seconds: Double
        /// Someone from the people directory this voice sounds like, offered on its chip
        /// until the user names it (J-03: proposed, never applied on its own).
        var suggestion: MeetingFlowModel.KnownPerson?
        /// People the user said it is not.
        var rejected: [UUID] = []
        /// The person the user confirmed this voice is, by id: two people may share a name.
        var personID: UUID?
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
    /// The words of the sentence each channel is saying now, before it is finished:
    /// shown under the last line and replaced as they come (EFFICIENCY.md E5).
    private(set) var liveDrafts: [Channel: TranscriptDraft] = [:]
    /// The vocabulary, read once per meeting and again when a voice is named.
    private var liveVocabulary: [VocabularyEntry] = []
    private var nextLineID = 0
    private(set) var translationState: TranslationState = .off
    private var translator: TranslationSession?
    /// Voices heard so far, in order of first appearance.
    private(set) var liveVoices: [LiveVoice] = []
    private var labeler = SpeakerLabeler()
    /// The live passes' models, once loaded: the end of the meeting uses them again.
    private var liveSeparator: SpeakerSeparator?
    private var liveEmbedder: SpeakerEmbedder?
    /// The others' sentences measured as they are heard (`SentencePrints`), one at a
    /// time and in the background.
    private var sentencePrints = SentencePrints()
    private var sentenceQueue: AsyncStream<TranscriptSegment>.Continuation?
    private var sentenceWorker: Task<Void, Never>?
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
    /// Why "me" is not being transcribed right now, or nil while it is (J-10).
    private(set) var microphoneMuted: MicrophoneGate.Reason?
    /// Whether the meeting app's own mute control could be read; when it cannot, the
    /// live panel's switch is the user's way to keep their words out.
    private(set) var muteControlReadable = false
    /// Counts a feature for the usage statistics (J-11); a no-op until the user said yes.
    var countUsage: (String, Int) -> Void = { _, _ in }
    private var microphoneGate: MicrophoneGate?
    private var muteReader: MuteControlReader?
    private var muteReadability: Task<Void, Never>?
    var preferences: MeetingPreferences

    let store: MeetingStore
    let environment: AppEnvironment
    private var monitor: AudioActivityMonitor?
    private var session: ListenSession?
    /// Apps already offered for their current microphone use: "Ahora no" is not asked
    /// again until the app closes the microphone and opens it again.
    private var declined: Set<String> = []
    /// An agent asked to stop when the call ends (`startForAgent`).
    private var stopsWhenCallEnds = false
    private var callEndCheck: Task<Void, Never>?
    /// The last meeting saved, for an agent waiting on it.
    private(set) var lastFinished: UUID?
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
        store.builtInText = MeetingCopy.builtInText
        preferences = MeetingPreferences.load(from: directory)
    }

    var directory: URL { store.directory }

    func start() {
        // A meeting a crash left unsaved comes back first, before anything reads the list.
        do {
            if let recovered = try store.recoverInProgress(suffix: MeetingCopy.t("meetings.recoveredSuffix")) {
                log.info("recovered an unsaved meeting of \(Int(recovered.duration)) s")
                lastFinished = recovered.id
            }
        } catch {
            log.error("could not recover the unsaved meeting: \(error)")
        }
        do {
            let removed = try store.purge(olderThan: preferences.retentionDays)
            if removed > 0 { log.info("retention removed \(removed) meetings") }
        } catch {
            log.error("retention purge failed: \(error)")
        }
        // People named in meetings saved before voices were kept start out recognised.
        do {
            let learnt = try store.learnVoicesFromHistory()
            if learnt > 0 { log.info("learnt \(learnt) voices from saved meetings") }
        } catch {
            log.error("learning voices from saved meetings failed: \(error)")
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
        case .listening(let app):
            guard stopsWhenCallEnds else { break }
            // The call ended when its app lets go of the microphone; twenty seconds
            // covers an app that reopens it (a device change, a helper restarting).
            if MeetingApp.recording(among: [app], processes: processes).isEmpty {
                guard callEndCheck == nil else { break }
                callEndCheck = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard let self, !Task.isCancelled, case .listening(let current) = self.phase, current == app else { return }
                    let now = (try? AudioProcesses.all()) ?? []
                    guard MeetingApp.recording(among: [app], processes: now).isEmpty else {
                        self.callEndCheck = nil
                        return
                    }
                    self.log.info("the call in \(app.name) ended; stopping as the agent asked")
                    await self.finish()
                }
            } else {
                callEndCheck?.cancel()
                callEndCheck = nil
            }
        case .separating:
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

    /// The menu's "Transcribe a meeting": the offer for the meeting app using the
    /// microphone now; else any other app using it (Quill does not know every meeting
    /// app); else the first meeting app with a running process — so the language can be
    /// chosen there too.
    func startFromMenu() {
        Task {
            let processes = (try? AudioProcesses.all()) ?? []
            let app = MeetingApp.recording(among: MeetingApp.known, processes: processes).first
                ?? MeetingApp.unlistedRecording(processes: processes).first.map(Self.unlistedApp)
                ?? MeetingApp.known.first { app in processes.contains { $0.bundleID.map(app.matches) ?? false } }
            guard let app else {
                lastError = MeetingCopy.t("meetings.error.noApp")
                NSSound.beep()
                return
            }
            offer(app)
        }
    }

    /// An app outside the list, named as the Finder names it.
    private static func unlistedApp(bundleID: String) -> MeetingApp {
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? bundleID
        return MeetingApp.unlisted(bundleID: bundleID, name: name)
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
        var configuration = ListenSession.Configuration(
            target: .bundleIDs(bundleIDs),
            sourceName: app.name,
            locale: Locale(identifier: language),
            includeMicrophone: preferences.includeMicrophone,
            keepsOthersAudio: preferences.separateSpeakers
        )
        #if DEBUG
        // The agent test (Scripts/meetings-agent.sh) plays synthetic audio: silenced, as T3.
        configuration.muteTarget = DebugHooks.value("QUILL_LISTEN_MUTE") != nil
        #endif
        let gate = MicrophoneGate()
        configuration.microphoneGate = gate
        let session = ListenSession(configuration: configuration)
        do {
            try await session.start(onSegment: { [weak self] segment in
                Task { @MainActor in self?.append(segment) }
            }, onHealth: { [weak self] channel, healthy in
                Task { @MainActor in self?.channelHealthChanged(channel, healthy: healthy) }
            }, onDraft: { [weak self] draft in
                Task { @MainActor in self?.draft(draft) }
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
        liveDrafts = [:]
        liveVocabulary = store.vocabulary()
        lostChannels = []
        startMicrophoneGate(gate, app: app)
        await setUpTranslation(language: language)
        startLiveDiarization()
        listeningSince = Date()
        lastError = nil
        phase = .listening(app)
        if preferences.showsLivePanel { showLivePanel(app: app) }
        checkpointLoop?.cancel()
        checkpointLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.checkpointInterval)
                guard !Task.isCancelled else { return }
                self?.checkpoint()
            }
        }
    }

    /// How often the meeting being recorded is written to disk.
    static let checkpointInterval: Duration = .seconds(30)
    private var checkpointLoop: Task<Void, Never>?

    /// Writes the meeting so far, with the names given during it, so a crash loses at
    /// most the last interval (MeetingStore.saveInProgress).
    private func checkpoint() {
        guard let session, case .listening(let app) = phase else { return }
        var transcript = session.snapshot()
        guard !transcript.segments.isEmpty else { return }
        for voice in liveVoices where !voice.name.isEmpty { transcript.names[voice.label] = voice.name }
        let started = listeningSince ?? Date()
        let record = MeetingRecord(
            id: inProgressID, title: String(localized: "meetings.defaultTitle \(app.name)", bundle: .localized),
            sourceApp: app.name, startedAt: started, duration: Date().timeIntervalSince(started), transcript: transcript)
        do {
            try store.saveInProgress(record)
        } catch {
            log.error("could not write the meeting in progress: \(error)")
        }
    }

    /// The recording's id, so every checkpoint overwrites the same meeting.
    private var inProgressID = UUID()

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

    // MARK: Microphone mute

    private func startMicrophoneGate(_ gate: MicrophoneGate, app: MeetingApp) {
        microphoneGate = gate
        microphoneMuted = gate.mutedReason
        gate.observe { [weak self] reason in
            Task { @MainActor in
                guard let self, self.microphoneGate === gate else { return }
                if self.microphoneMuted != reason {
                    self.log.info("microphone \(reason.map { "muted: \($0.rawValue)" } ?? "live")")
                }
                self.microphoneMuted = reason
            }
        }
        let reader = MuteControlReader(app: app, gate: gate)
        reader.start()
        muteReader = reader
        muteReadability = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.muteControlReadable = gate.appControl != nil
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stopMicrophoneGate() {
        muteReader?.stop()
        muteReader = nil
        muteReadability?.cancel()
        muteReadability = nil
        microphoneGate = nil
        microphoneMuted = nil
        muteControlReadable = false
    }

    /// The live panel's switch: keep "me" out of the transcript whatever the app says.
    func toggleMicrophone() {
        guard let gate = microphoneGate else { return }
        gate.setUserMuted(!gate.isUserMuted)
        if gate.isUserMuted { countUsage("microphone_muted_in_quill", 1) }
    }

    var isMicrophoneMutedInQuill: Bool { microphoneMuted == .mutedInQuill }

    /// Whether this meeting records the user's microphone at all.
    var includesMicrophone: Bool { microphoneGate != nil && preferences.includeMicrophone }

    private func append(_ segment: TranscriptSegment) {
        if liveDrafts[segment.channel].map({ $0.start < segment.end }) ?? false { liveDrafts[segment.channel] = nil }
        let line = LiveLine(id: nextLineID, segment: segment,
                            text: liveText(segment.text, label: segment.channel == .me ? "me" : nil))
        nextLineID += 1
        liveLines.append(line)
        if liveLines.count > 80 { liveLines.removeFirst(liveLines.count - 80) }
        if segment.channel == .others { sentenceQueue?.yield(segment) }
        translate(line)
    }

    private func draft(_ draft: TranscriptDraft) {
        guard session != nil else { return }
        let text = liveText(draft.text, label: draft.channel == .me ? "me" : nil)
        liveDrafts[draft.channel] = text.isEmpty ? nil
            : TranscriptDraft(channel: draft.channel, start: draft.start, end: draft.end, text: text)
    }

    /// A live line written with the vocabulary of whoever said it: the user's, the
    /// person a voice was named as, or everybody's while nobody knows who it is.
    private func liveText(_ text: String, label: String?) -> String {
        guard !liveVocabulary.isEmpty else { return text }
        var scope: VocabularyEntry.Scope?
        if label == "me" {
            scope = .me
        } else if let label, let voice = liveVoices.first(where: { $0.label == label }) {
            scope = (voice.personID ?? store.person(named: voice.name)?.id).map { .person($0) }
        }
        return Vocabulary.apply(liveVocabulary.filter { $0.scope == .global || $0.scope == scope }, to: text)
    }

    /// Lines of the others written again once their voice is known or named.
    private func rewriteLiveLines() {
        for index in liveLines.indices where liveLines[index].segment.channel == .others {
            liveLines[index].text = liveText(liveLines[index].segment.text, label: liveLines[index].speaker)
        }
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

    /// Every two minutes, and further apart as a pass grows costly (`LivePassSchedule`),
    /// the others' audio so far is separated again, in the background, and its voices labelled to continue the previous pass
    /// (`SpeakerLabeler`). Measured on the bench (TESTING-MEETINGS.md): a name given in
    /// the first minutes points at the right person for 75–80 % of the speech, about
    /// 90 % from minute eight; a voice close to another may only appear later.
    private func startLiveDiarization() {
        liveVoices = []
        labeler = SpeakerLabeler()
        guard preferences.separateSpeakers else { return }
        let separator = SpeakerSeparator(modelsDirectory: directory.appendingPathComponent("models", isDirectory: true))
        let embedder = SpeakerEmbedder(modelsDirectory: directory.appendingPathComponent("models/streaming", isDirectory: true))
        sentencePrints = SentencePrints()
        let (sentences, queue) = AsyncStream<TranscriptSegment>.makeStream()
        sentenceQueue = queue
        diarizationLoop = Task { @MainActor [weak self] in
            if (try? await separator.prepare()) != nil { self?.liveSeparator = separator }
            if (try? await embedder.prepare()) != nil {
                self?.liveEmbedder = embedder
                self?.startMeasuringSentences(sentences, embedder: embedder)
            }
            let schedule = LivePassSchedule()
            var interval = schedule.first
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                let began = ContinuousClock.now
                await self.runDiarizationPass(separator)
                interval = schedule.interval(after: ContinuousClock.now - began)
            }
        }
    }

    /// Each of the others' sentences gets its voiceprint when it is heard, so the end of
    /// the meeting only measures the ones the final separation cuts differently.
    private func startMeasuringSentences(_ sentences: AsyncStream<TranscriptSegment>, embedder: SpeakerEmbedder) {
        sentenceWorker = Task { @MainActor [weak self] in
            for await segment in sentences {
                guard let session = self?.session else { return }
                let span = SentencePrints.span(of: segment)
                guard span.end - span.start >= SpeakerEmbedder.minimumSeconds else { continue }
                let print = await Task.detached(priority: .utility) { () -> [Float]? in
                    let samples = session.othersAudio(from: span.start, to: span.end)
                    guard samples.count >= Int(SpeakerEmbedder.minimumSeconds * AudioAccumulator.sampleRate) else { return nil }
                    return try? embedder.voiceprint(of: samples)
                }.value
                guard !Task.isCancelled, let self, self.session === session, let print else { continue }
                self.sentencePrints.keep(Voiceprint(print), from: span.start, to: span.end)
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
        await suggestLivePeople(turns: labelled, samples: samples)
    }

    /// Each unnamed voice measured on its longest turns and compared with the people
    /// directory (`VoiceRecognition`), off the main thread.
    private func suggestLivePeople(turns: [SpeakerTurn], samples: [Float]) async {
        guard let embedder = liveEmbedder else { return }
        let people = store.people().filter { !($0.voices ?? []).isEmpty }
        guard !people.isEmpty else { return }
        let unnamed = Set(liveVoices.filter { $0.name.isEmpty }.map(\.label))
        let voices = await Task.detached(priority: .utility) { () -> [String: Voiceprint] in
            Self.measureVoices(turns: turns.filter { unnamed.contains($0.speaker) }, samples: samples, embedder: embedder)
        }.value
        let named = Dictionary(liveVoices.compactMap { voice in
            (voice.personID ?? store.person(named: voice.name)?.id).map { (voice.label, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let rejected = Dictionary(uniqueKeysWithValues: liveVoices.map { ($0.label, $0.rejected) })
        let suggestions = VoiceRecognition.suggestions(voices: voices, people: people, named: named, rejected: rejected)
        let known = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in liveVoices.indices where liveVoices[index].name.isEmpty {
            liveVoices[index].suggestion = suggestions[liveVoices[index].label].flatMap { known[$0.personID] }
                .map { MeetingFlowModel.KnownPerson(id: $0.id, name: $0.name, roleID: $0.roleID) }
        }
    }

    /// A voiceprint per voice from its four longest turns of at least 1.5 s.
    nonisolated static func measureVoices(turns: [SpeakerTurn], samples: [Float], embedder: SpeakerEmbedder) -> [String: Voiceprint] {
        let rate = AudioAccumulator.sampleRate
        var segments: [TranscriptSegment] = []
        for (speaker, group) in Dictionary(grouping: turns, by: \.speaker) {
            for turn in group.filter({ $0.end - $0.start >= 1.5 }).sorted(by: { $0.end - $0.start > $1.end - $1.start }).prefix(4) {
                let first = max(0, Int(turn.start * rate)), last = min(samples.count, Int(turn.end * rate))
                guard last > first, let print = try? embedder.voiceprint(of: Array(samples[first..<last])) else { continue }
                segments.append(TranscriptSegment(channel: .others, start: turn.start, end: turn.end, text: "",
                                                  speaker: speaker, voiceprint: Voiceprint(print)))
            }
        }
        return VoiceRecognition.voices(of: Transcript(startedAt: Date(), locale: "", source: "", segments: segments))
    }

    /// The chip's "is it Fran?" answered yes.
    func acceptLiveSuggestion(_ label: String) {
        guard let voice = liveVoices.first(where: { $0.label == label }), let person = voice.suggestion else { return }
        nameLiveVoice(label, name: person.name, roleID: person.roleID)
        if let index = liveVoices.firstIndex(where: { $0.label == label }) { liveVoices[index].personID = person.id }
        countUsage("voices_recognised", 1)
    }

    /// Answered no: not offered again for this voice in this meeting.
    func rejectLiveSuggestion(_ label: String) {
        guard let index = liveVoices.firstIndex(where: { $0.label == label }), let person = liveVoices[index].suggestion else { return }
        liveVoices[index].rejected.append(person.id)
        liveVoices[index].suggestion = nil
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
        rewriteLiveLines()
    }

    func nameLiveVoice(_ label: String, name: String, roleID: String?) {
        guard let index = liveVoices.firstIndex(where: { $0.label == label }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if MeetingStore.fold(trimmed) != MeetingStore.fold(liveVoices[index].name) { liveVoices[index].personID = nil }
        liveVoices[index].name = trimmed
        liveVoices[index].roleID = roleID
        defer { rewriteLiveLines() }
        liveVoices[index].suggestion = nil
    }

    /// What the live panel calls a voice: its name, else "Persona N".
    func liveName(_ label: String) -> String {
        if let voice = liveVoices.first(where: { $0.label == label }), !voice.name.isEmpty { return voice.name }
        let number = label.split(separator: "-").last.map(String.init) ?? label
        return String(localized: "label.person \(number)", bundle: .localized)
    }

    var roles: [MeetingRole] { store.roles() }

    /// Stops the live passes and hands over their models, loaded, for the final pass.
    @discardableResult
    private func stopLiveDiarization() async -> (separator: SpeakerSeparator?, embedder: SpeakerEmbedder?) {
        diarizationLoop?.cancel()
        diarizationLoop = nil
        sentenceQueue?.finish()
        sentenceQueue = nil
        sentenceWorker?.cancel()
        sentenceWorker = nil
        await diarizationPass?.value
        defer {
            liveSeparator = nil
            liveEmbedder = nil
        }
        return (liveSeparator, liveEmbedder)
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

    /// Stops listening, tells the voices apart and opens the meeting. Returns its id.
    @discardableResult
    func finish() async -> UUID? {
        guard let session, case .listening(let app) = phase else { return nil }
        stopsWhenCallEnds = false
        callEndCheck?.cancel()
        callEndCheck = nil
        hideLivePanel()
        let started = listeningSince ?? Date()
        // Written before the audio stops: stopping it is where Quill crashed on 2026-11-12.
        checkpoint()
        checkpointLoop?.cancel()
        checkpointLoop = nil
        phase = .separating
        let captured = session.secondsCaptured
        var transcript = await session.stop()
        stopMicrophoneGate()
        log.info("capture: \(session.diagnostics.joined(separator: " | "))")
        lostChannels = []
        let samples = session.takeOthersAudio()
        let live = await stopLiveDiarization()
        let heard = sentencePrints
        sentencePrints = SentencePrints()
        self.session = nil

        var people: [String: UUID] = [:]
        if preferences.separateSpeakers, !samples.isEmpty, transcript.segments.contains(where: { $0.channel == .others }) {
            let clock = ContinuousClock()
            let began = clock.now
            do {
                // A meeting stopped before the live models loaded loads them now.
                let separator: SpeakerSeparator
                if let loaded = live.separator {
                    separator = loaded
                } else {
                    separator = SpeakerSeparator(modelsDirectory: directory.appendingPathComponent("models", isDirectory: true))
                    try await separator.prepare()
                }
                // Voices that barely speak are interruptions heard as a new person (TESTING-MEETINGS.md).
                // Labelled to continue the live passes, so names given during the meeting stay.
                let turns = labeler.label(SpeakerTurn.absorbingMinorVoices(try await separator.turns(for: samples)))
                transcript = transcript.assigningSpeakers(turns, renumbering: false)
                // Each sentence's voiceprint, while the audio is still here: what lets the
                // user split a voice that holds two people (VOICES.md S1).
                let separated = clock.now
                var embedder = live.embedder
                if embedder == nil {
                    let fresh = SpeakerEmbedder(
                        modelsDirectory: directory.appendingPathComponent("models/streaming", isDirectory: true))
                    if (try? await fresh.prepare()) != nil { embedder = fresh }
                }
                if let embedder {
                    // Off the main thread: the sentences not measured during the meeting
                    // take about 60 ms each.
                    let unmeasured = transcript
                    transcript = await Task.detached(priority: .userInitiated) {
                        embedder.measuringSegments(of: unmeasured, samples: samples, known: heard)
                    }.value
                }
                let measured = transcript.segments.filter { $0.voiceprint != nil }
                let reused = measured.filter { heard.print(from: $0.start, to: $0.end) != nil }.count
                log.info("separation: \(separated - began) for \(Int(Double(samples.count) / AudioAccumulator.sampleRate)) s of audio; voiceprints: \(clock.now - separated), \(reused) of \(measured.count) measured during the meeting")
                // Each named voice goes to the person the user confirmed, or the one its name
                // and voice point to; a name several people share waits for the user to
                // choose in the meeting window (EFFICIENCY.md E4).
                let prints = VoiceRecognition.voices(of: transcript)
                for voice in liveVoices where !voice.name.isEmpty && transcript.segments.contains(where: { $0.speaker == voice.label }) {
                    transcript.names[voice.label] = voice.name
                    var personID = voice.personID
                    if personID == nil {
                        switch store.match(name: voice.name, voice: prints[voice.label]) {
                        case .person(let id): personID = id
                        case .new: break
                        case .ambiguous: continue
                        }
                    }
                    if let person = try? store.remember(personID, name: voice.name, roleID: voice.roleID, at: started) {
                        people[voice.label] = person.id
                    }
                }
            } catch {
                log.error("diarization failed: \(error)")
                lastError = MeetingCopy.t("meetings.error.separation")
            }
        }

        var record = MeetingRecord(
            title: String(localized: "meetings.defaultTitle \(app.name)", bundle: .localized),
            sourceApp: app.name,
            startedAt: started,
            duration: Date().timeIntervalSince(started),
            transcript: transcript,
            people: people,
            capturedSeconds: Dictionary(uniqueKeysWithValues: captured.map { ($0.key.rawValue, $0.value) })
        )
        // Written with the vocabulary of whoever said each sentence: everybody's, the
        // user's own, and that of people named during the meeting.
        record = store.applyingVocabulary(to: record)
        for channel in record.silentChannels {
            log.error("meeting saved with little audio from \(channel.rawValue): \(captured[channel] ?? 0) s of \(record.duration) s")
        }
        do {
            try store.save(record)
            store.clearInProgress()
            inProgressID = UUID()
            countUsage("meetings", 1)
            countUsage("meeting_minutes", Int((record.duration / 60).rounded()))
        } catch {
            log.error("could not save the meeting: \(error)")
        }
        phase = .idle
        listeningSince = nil
        liveLines = []
        liveDrafts = [:]
        liveVoices = []
        stopTranslation()
        openMeeting(record.id, step: .people)
        lastFinished = record.id
        return record.id
    }

    /// Stops without keeping anything.
    func discard() async {
        guard let session else { return }
        checkpointLoop?.cancel()
        checkpointLoop = nil
        store.clearInProgress()
        inProgressID = UUID()
        hideLivePanel()
        await stopLiveDiarization()
        liveVoices = []
        _ = await session.stop()
        stopMicrophoneGate()
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
        liveLines = segments.enumerated().map { LiveLine(id: $0.offset, segment: $0.element, text: $0.element.text) }
        showLivePanel(app: app)
    }

    /// Snapshot support: a sentence still being said, under the last line.
    func debugDraft(_ text: String, channel: Channel) {
        liveDrafts[channel] = TranscriptDraft(channel: channel, start: 0, end: 1, text: text)
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
    /// Voices as a live pass would leave them: a label per line (nil for the user's own),
    /// and names for some.
    func debugLiveVoices(lineSpeakers: [String?], names: [String: String], roles: [String: String]) {
        var labels: [String] = []
        for (index, label) in lineSpeakers.enumerated() where liveLines.indices.contains(index) {
            guard let label, liveLines[index].segment.channel == .others else { continue }
            liveLines[index].speaker = label
            if !labels.contains(label) { labels.append(label) }
        }
        liveVoices = labels.map { LiveVoice(label: $0, name: names[$0] ?? "", roleID: roles[$0], seconds: 30) }
    }
    /// Snapshot support: an unnamed live voice proposed as someone from the directory.
    func debugSuggestLiveVoice(_ label: String, as name: String, roleID: String?) {
        guard let index = liveVoices.firstIndex(where: { $0.label == label }) else { return }
        liveVoices[index].suggestion = MeetingFlowModel.KnownPerson(id: UUID(), name: name, roleID: roleID)
    }
    /// Snapshot support: the microphone muted for `reason`, as the gate would say.
    func debugMicrophoneMuted(_ reason: MicrophoneGate.Reason?) {
        microphoneMuted = reason
    }
    func debugTranslate(_ translations: [String]) {
        // Only the others' words are translated, as in a meeting.
        for (index, text) in translations.enumerated() where liveLines.indices.contains(index) && liveLines[index].segment.channel == .others {
            liveLines[index].translation = text
        }
        let language = Bundle.main.preferredLocalizations.first ?? "es"
        translationState = .active(target: Locale(identifier: language).localizedString(forLanguageCode: language) ?? language)
    }
    func debugMeetingWindow(_ id: UUID) -> NSWindow? { meetingWindows[id]?.shownWindow }
    func debugMeetingModel(_ id: UUID) -> MeetingFlowModel? { meetingWindows[id]?.debugModel }
    var debugFocusEditorWindow: NSWindow? { focusEditor?.shownWindow }
    #endif

    // MARK: Agents

    /// The apps that could hold a meeting now: every known meeting app with a process
    /// Core Audio sees, and any other app with the microphone open, each saying whether it
    /// is in a call (records) and plays sound. What an agent chooses from (E7).
    func meetingAppsForAgent() -> AgentReply {
        let processes = (try? AudioProcesses.all()) ?? []
        var lines: [String] = []
        func describe(_ app: MeetingApp) -> String? {
            let mine = processes.filter { $0.bundleID.map(app.matches) ?? false }
            guard !mine.isEmpty else { return nil }
            let call = mine.contains(where: \.isRunningInput)
            let sound = mine.contains(where: \.isRunningOutput)
            let state = call ? "in a call (microphone open)" : "open, not in a call"
            return "- \(app.id) · \(app.name) · \(state)\(sound ? ", playing sound" : "")\(app.isBrowser ? " · a browser: the call may be Meet or another web app" : "")"
        }
        lines += MeetingApp.known.compactMap(describe)
        lines += MeetingApp.unlistedRecording(processes: processes).map(Self.unlistedApp).compactMap(describe)
        let header = agentState
        guard !lines.isEmpty else {
            return AgentReply(text: header + "\nNo meeting app is open. When one is, start_listening can transcribe it.",
                              details: ["state": agentStateName])
        }
        return AgentReply(text: header + "\nApps (id · name · state):\n" + lines.joined(separator: "\n")
                            + "\nstart_listening takes one of these ids; without one it picks the app in a call.",
                          details: ["state": agentStateName])
    }

    /// What Quill is doing, in a line, for an agent.
    private var agentState: String {
        switch phase {
        case .listening(let app):
            let minutes = Int((Date().timeIntervalSince(listeningSince ?? Date()) / 60).rounded())
            return "Quill is transcribing \(app.name) (\(minutes) min so far)."
        case .separating: return "The meeting just ended; Quill is telling the voices apart."
        case .offering(let app): return "Quill is offering to transcribe \(app.name); nothing is being transcribed."
        case .idle: return "Quill is not transcribing."
        }
    }

    private var agentStateName: String {
        switch phase {
        case .listening: "listening"
        case .separating: "separating"
        case .offering: "offering"
        case .idle: "idle"
        }
    }

    /// Starts transcribing for an agent: the app it names (by id from
    /// `meetingAppsForAgent`, or by name), else the app in a call now. The user sees the
    /// live panel as when they start it themselves.
    func startForAgent(appID: String?, language: String?, stopWhenCallEnds: Bool) async -> AgentReply {
        switch phase {
        case .listening(let app):
            return .failure("Quill is already transcribing \(app.name). stop_listening ends it first.")
        case .separating:
            return .failure("Quill is saving the meeting that just ended; try again in a moment.")
        case .idle, .offering:
            break
        }
        if let language, !MeetingPreferences.languages.contains(language) {
            return .failure("Quill does not transcribe “\(language)”. It can: \(MeetingPreferences.languages.joined(separator: ", ")).")
        }
        let processes = (try? AudioProcesses.all()) ?? []
        let app: MeetingApp?
        if let appID {
            let wanted = appID.trimmingCharacters(in: .whitespaces)
            app = MeetingApp.known.first { $0.id.caseInsensitiveCompare(wanted) == .orderedSame
                || $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
                ?? (wanted.hasPrefix("app:") ? Self.unlistedApp(bundleID: String(wanted.dropFirst(4))) : nil)
            guard app != nil else { return .failure("No meeting app “\(appID)”. list_meeting_apps lists them.") }
        } else {
            app = MeetingApp.recording(among: MeetingApp.known, processes: processes).first
                ?? MeetingApp.unlistedRecording(processes: processes).first.map(Self.unlistedApp)
            guard app != nil else {
                return .failure("No app is in a call now. list_meeting_apps shows what is open; pass app_id to choose one.")
            }
        }
        guard let app else { return .failure("No meeting app to transcribe.") }
        await startListening(to: app, language: language)
        guard case .listening = phase else {
            return .failure(lastError ?? offerError ?? "Quill could not start transcribing \(app.name).")
        }
        stopsWhenCallEnds = stopWhenCallEnds
        countUsage("meetings_started_by_agent", 1)
        let languageName = MeetingPreferences.languageName(language ?? preferences.localeIdentifier)
        return AgentReply(
            text: "Transcribing \(app.name) in \(languageName). The user sees Quill's live panel."
                + (stopWhenCallEnds ? " Quill stops and saves the meeting when the call ends; wait_for_meeting returns it."
                                    : " stop_listening ends it and saves the meeting."),
            details: ["state": "listening", "app": app.name, "language": languageName])
    }

    /// What is being transcribed, with the last lines heard, for an agent.
    func statusForAgent(lines count: Int) -> AgentReply {
        guard case .listening = phase else { return AgentReply(text: agentState, details: ["state": agentStateName]) }
        var lines = [agentState]
        let voices = liveVoices.map { voice in
            (voice.name.isEmpty ? liveName(voice.label) : voice.name) + " (\(Int(voice.seconds)) s)"
        }
        if !voices.isEmpty { lines.append("Voices so far: " + voices.joined(separator: ", ")) }
        if !lostChannels.isEmpty {
            lines.append("Warning: " + lostChannels.map { $0 == .me ? "the user's microphone" : "the others' audio" }
                .joined(separator: " and ") + " stopped arriving; Quill is reconnecting.")
        }
        if let reason = microphoneMuted { lines.append("The user's microphone is not being transcribed (\(reason.rawValue)).") }
        let shown = liveLines.suffix(max(0, count))
        if !shown.isEmpty {
            lines.append("")
            lines.append("Last \(shown.count) lines (live, before the voices are separated at the end):")
            for line in shown {
                let who = line.segment.channel == .me ? MeetingCopy.t("label.me")
                    : line.speaker.map(liveName) ?? MeetingCopy.t("label.others")
                lines.append("[\(MeetingCopy.clock(line.segment.start))] \(who): \(line.text)")
            }
        }
        for draft in [Channel.others, .me].compactMap({ liveDrafts[$0] }) {
            lines.append("(being said) " + (draft.channel == .me ? MeetingCopy.t("label.me") : MeetingCopy.t("label.others"))
                         + ": " + draft.text)
        }
        return AgentReply(text: lines.joined(separator: "\n"), details: ["state": "listening"])
    }

    /// Stops transcribing for an agent and says where the meeting is.
    func stopForAgent() async -> AgentReply {
        guard case .listening = phase else { return .failure(agentState) }
        guard let id = await finish() else { return .failure("Quill could not save the meeting.") }
        return savedReply(id)
    }

    /// Waits for the meeting being transcribed to end, as the user stops it or the call
    /// ends (`stopWhenCallEnds`), up to `seconds`.
    func waitForAgent(seconds: Int) async -> AgentReply {
        let before = lastFinished
        guard isListening || phase == .separating else {
            if let last = lastFinished { return savedReply(last) }
            return .failure("Quill is not transcribing. start_listening starts it.")
        }
        let deadline = Date().addingTimeInterval(Double(seconds))
        while Date() < deadline {
            if let last = lastFinished, last != before { return savedReply(last) }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return AgentReply(text: agentState + " Still going after \(seconds) s; call wait_for_meeting again to keep waiting.",
                          details: ["state": agentStateName])
    }

    private func savedReply(_ id: UUID) -> AgentReply {
        guard let record = store.meeting(id) else { return .failure("The meeting was saved but can no longer be read.") }
        let people = store.people(in: record).map { person in person.role.map { "\(person.name) (\($0.name))" } ?? person.name }
        let unnamed = record.labels.filter { $0 != "me" && record.transcript.names[$0] == nil }.count
        return AgentReply(
            text: "Saved “\(record.title)”, \(max(1, Int((record.duration / 60).rounded()))) min, id \(record.id.uuidString)."
                + (people.isEmpty ? "" : " People: \(people.joined(separator: ", ")).")
                + (unnamed > 0 ? " \(unnamed) voices have no name yet: the user names them in Quill's meeting window." : "")
                + " get_transcript and synthesize_meeting take this id.",
            details: ["state": agentStateName, "meetingId": record.id.uuidString, "title": record.title])
    }

    /// A synthesis asked for by an agent (docs/initiatives/mac-apps-mcp/DESIGN.md): the same
    /// path as the Synthesise button — model, consent, weighting, saving — through the
    /// meeting's open window when there is one, so the two never write over each other.
    func synthesizeForAgent(meetingID: UUID, focusID: String?) async -> AgentReply {
        let model: MeetingFlowModel
        if let open = meetingWindows[meetingID]?.flowModel {
            model = open
        } else {
            guard let record = store.meeting(meetingID) else {
                return .failure("That meeting is no longer in Quill.")
            }
            model = MeetingFlowModel(record: record, coordinator: self, step: .synthesis)
        }
        guard !model.running else { return .failure("Quill is already synthesising this meeting. Try again in a moment.") }
        if let focusID {
            guard model.focuses.contains(where: { $0.id == focusID }) else { return .failure("No focus with id \(focusID).") }
            model.focusID = focusID
        }
        let before = model.result?.id
        await model.synthesize()
        if let provider = model.consentProvider {
            model.declineConsent()
            return .failure("""
                The first time a meeting goes to \(provider), Quill asks the user. Ask them to open the \
                meeting in Quill and press Synthesise once; after that agents can ask for syntheses.
                """)
        }
        guard let result = model.result, result.id != before else {
            return .failure(model.error ?? "Quill could not synthesise the meeting.")
        }
        return AgentReply(text: result.text, details: [
            "meeting": model.record.title,
            "focus": store.displayName(of: result),
            "model": result.model,
        ].merging(result.isDraft ? ["draft": "on-device model; owners and dates may be wrong"] : [:]) { $1 })
    }

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

    /// Renames a meeting from the history: through its window when it is open, so the
    /// window's copy of the meeting is the one saved and nothing overwrites the name.
    func renameMeeting(_ id: UUID, to title: String) {
        if let open = meetingWindows[id]?.flowModel {
            open.rename(title)
            return
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var record = store.meeting(id), record.title != trimmed else { return }
        record.title = trimmed
        do {
            try store.save(record)
            countUsage("meetings_renamed", 1)
        } catch {
            log.error("could not rename the meeting: \(error)")
        }
        meetingChanged()
    }
}

// The Translation framework's session is used only from the main actor here (the
// coordinator's serial queue and the live panel's download task), never concurrently.
extension TranslationSession: @retroactive @unchecked Sendable {}
