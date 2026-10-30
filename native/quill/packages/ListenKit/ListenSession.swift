import AVFAudio
import CoreAudio
import Accelerate
import Foundation
import Speech

/// One meeting being transcribed: the meeting app's output as `others`, optionally the
/// microphone as `me`, each through its own on-device transcriber.
///
/// Audio never leaves memory: every block is converted, handed to the model and dropped.
/// What survives `stop()` is the `Transcript`.
///
/// **A watchdog keeps both captures alive.** Devices change under a meeting: a Bluetooth
/// headset switches profile when its microphone opens, the meeting app reconfigures
/// audio when the call starts. Measured on 2026-10-08 in a Teams call with AirPods: the
/// others' capture delivered nothing from the start and the microphone stopped at
/// 2 min 18 s, both silently, and the meeting was saved as one person talking. Every two
/// seconds the session checks that each capture still delivers; one that stalls is
/// rebuilt, the gap is filled with silence so the channels stay aligned, and `onHealth`
/// tells the interface.
public final class ListenSession: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var target: ProcessTap.Target
        public var sourceName: String
        public var locale: Locale
        public var includeMicrophone: Bool
        /// Silence the tapped app while listening. Tests only.
        public var muteTarget: Bool
        /// Keep the others' audio in memory until the end, so voices can be told apart
        /// over the whole meeting (`takeOthersAudio()`). Never written to disk.
        public var keepsOthersAudio: Bool
        /// See `ProcessTap(tapOnly:)`. Only experiments turn it off.
        public var tapOnly = true
        public var echoCancellation = true
        /// Open the microphone first and let a Bluetooth headset switch to its call
        /// profile before the tap is built.
        public var microphoneFirst = false
        /// How long a capture may deliver nothing before it is rebuilt.
        public var stallTimeout: Duration = .seconds(3)
        /// Decides when "me" may be transcribed (`MicrophoneGate`). The session tells it
        /// whether the meeting app holds a microphone; the app tells it the rest.
        public var microphoneGate: MicrophoneGate?
        /// Record from the microphone the meeting app records from, not the default.
        public var followsAppMicrophone = true
        /// How long the microphone's audio waits before it is transcribed, so a mute
        /// noticed a moment late still covers what was said in that moment.
        public var gateDelay: Double = 0.6

        public init(
            target: ProcessTap.Target,
            sourceName: String,
            locale: Locale = Locale(identifier: "es_ES"),
            includeMicrophone: Bool = true,
            muteTarget: Bool = false,
            keepsOthersAudio: Bool = false
        ) {
            self.target = target
            self.sourceName = sourceName
            self.locale = locale
            self.includeMicrophone = includeMicrophone
            self.muteTarget = muteTarget
            self.keepsOthersAudio = keepsOthersAudio
        }
    }

    public let configuration: Configuration
    private let lock = NSLock()
    private var transcript: Transcript
    private var tap: ProcessTap?
    private var microphone: MicrophoneCapture?
    private var transcribers: [ChannelTranscriber] = []
    private var othersTranscriber: ChannelTranscriber?
    private var meTranscriber: ChannelTranscriber?
    private var reservedLocale: Locale?
    private let othersAudio = AudioAccumulator()
    private var onSegment: (@Sendable (TranscriptSegment) -> Void)?
    private var onHealth: (@Sendable (Channel, Bool) -> Void)?
    private var startedAt = ContinuousClock.now
    private var watchdog: Task<Void, Never>?
    private var tapRebuilds = 0
    private let othersLevel = LevelMeter()
    private let meLevel = LevelMeter()
    private var appMicrophoneLoop: Task<Void, Never>?

    /// How loud each channel is right now, 0…1: what the recording indicator breathes
    /// with. Read as often as a frame is drawn; costs a lock.
    public var levels: (others: Float, me: Float) { (othersLevel.value, meLevel.value) }

    public init(configuration: Configuration) {
        self.configuration = configuration
        transcript = Transcript(
            startedAt: Date(),
            locale: configuration.locale.identifier,
            source: configuration.sourceName
        )
    }

    /// Reserves the language, prepares the models and starts both captures.
    ///
    /// - Parameter onHealth: a channel stopped delivering audio (`false`) or came back
    ///   (`true`). Called from the watchdog, off the main thread.
    public func start(
        onSegment: (@Sendable (TranscriptSegment) -> Void)? = nil,
        onHealth: (@Sendable (Channel, Bool) -> Void)? = nil
    ) async throws {
        self.onSegment = onSegment
        self.onHealth = onHealth
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: configuration.locale)
        else { throw ListenError.localeUnsupported(configuration.locale.identifier) }
        // The model is only readable while the app holds the language (measured in Ámbar:
        // `supported` before reserving, `installed` after). Released in `stop()`.
        // Meetings are the only reason Quill reserves a language, so any other reservation
        // is a leftover: a session that failed before `stop()` kept its language, and the
        // system caps reservations per app. Once full, `reserve` fails and an installed
        // model reads as missing (2026-10-08: en_GB installed, "not installed" after a
        // restart). Released before reserving.
        for leftover in await AssetInventory.reservedLocales where leftover != locale {
            _ = await AssetInventory.release(reservedLocale: leftover)
        }
        do {
            _ = try await AssetInventory.reserve(locale: locale)
        } catch {
            NSLog("Quill meetings: reserving %@ failed: %@", locale.identifier, String(describing: error))
        }
        reservedLocale = locale
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        // A model installed by another process is not Quill's until Quill asks for it:
        // measured on 2026-10-08, en_US and en_GB installed by a script read as missing
        // here. Asking installs it under Quill's own reservation (a no-op when present).
        if await AssetInventory.status(forModules: [probe]) != .installed {
            do {
                try await AssetInventory.assetInstallationRequest(supporting: [probe])?.downloadAndInstall()
            } catch {
                NSLog("Quill meetings: installing the %@ model failed: %@", locale.identifier, String(describing: error))
            }
        }
        guard await AssetInventory.status(forModules: [probe]) == .installed else {
            _ = await AssetInventory.release(reservedLocale: locale)
            reservedLocale = nil
            throw ListenError.modelNotInstalled(locale.identifier)
        }

        let others = try await ChannelTranscriber(channel: .others, locale: locale)
        transcribers.append(others)
        othersTranscriber = others
        try await others.start { [weak self] in self?.record($0) }

        if configuration.includeMicrophone {
            let me = try await ChannelTranscriber(channel: .me, locale: locale)
            transcribers.append(me)
            meTranscriber = me
            try await me.start { [weak self] in self?.record($0) }
        }

        // Both channels count time from here: a block that arrives later than the audio
        // fed so far is preceded by silence (`padSilence`).
        startedAt = .now
        if configuration.includeMicrophone, configuration.microphoneFirst {
            try startMicrophone()
            try? await Task.sleep(for: .milliseconds(1_500))
        }
        try startTap()
        if configuration.includeMicrophone, !configuration.microphoneFirst {
            try startMicrophone()
        }
        startWatchdog()
    }

    /// Seconds since `origin`, for stamping blocks against the session's clock.
    private static func seconds(since origin: ContinuousClock.Instant) -> Double {
        let duration = origin.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func startTap() throws {
        guard let others = othersTranscriber else { return }
        let tap = try ProcessTap(target: configuration.target, muted: configuration.muteTarget,
                                 tapOnly: configuration.tapOnly)
        let accumulator = configuration.keepsOthersAudio ? othersAudio : nil
        let origin = startedAt
        let level = othersLevel
        try tap.start { buffer in
            level.measure(buffer)
            // What the capture missed before this block, as silence; then the block.
            let blockStart = Self.seconds(since: origin) - Double(buffer.frameLength) / buffer.format.sampleRate
            others.padSilence(upTo: blockStart)
            accumulator?.padSilence(upTo: blockStart)
            others.append(buffer)
            accumulator?.append(buffer)
        }
        lock.withLock { self.tap = tap }
    }

    private func startMicrophone() throws {
        guard let me = meTranscriber else { return }
        let microphone = MicrophoneCapture(echoCancellation: configuration.echoCancellation)
        if configuration.followsAppMicrophone, let device = appMicrophone().device {
            microphone.use(device: device)
        }
        let origin = startedAt
        let level = meLevel
        let feed = GatedFeed(gate: configuration.microphoneGate, delay: configuration.gateDelay) { buffer, start in
            level.measure(buffer)
            me.padSilence(upTo: start)
            me.append(buffer)
        }
        try microphone.start { buffer in
            feed.push(buffer, start: Self.seconds(since: origin) - Double(buffer.frameLength) / buffer.format.sampleRate)
        }
        lock.withLock {
            self.microphone = microphone
            self.gatedFeed = feed
        }
        startAppMicrophoneLoop()
    }

    private var gatedFeed: GatedFeed?

    /// What the meeting app does with the microphone now: whether any of its processes
    /// records, and from which device. Unknown (nil) for a target given by process ids.
    private func appMicrophone() -> (holds: Bool?, device: AudioDeviceID?) {
        guard case .bundleIDs(let bundleIDs) = configuration.target else { return (nil, nil) }
        let processes = ((try? AudioProcesses.all()) ?? []).filter { process in
            process.bundleID.map { id in bundleIDs.contains { id.hasPrefix($0) } } ?? false
        }
        let recording = processes.filter(\.isRunningInput)
        let device = recording.lazy.compactMap { AudioProcesses.inputDevices(of: $0.objectID).first }.first
        return (!recording.isEmpty, device)
    }

    /// Four times a second: does the meeting app still record, and from which microphone?
    /// Cheap (one Core Audio listing); fast enough that the gate's delay covers it.
    private func startAppMicrophoneLoop() {
        guard case .bundleIDs = configuration.target else { return }
        let gate = configuration.microphoneGate
        let follows = configuration.followsAppMicrophone
        appMicrophoneLoop = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let state = self.appMicrophone()
                gate?.setAppHoldsMicrophone(state.holds)
                if follows, let device = state.device {
                    self.lock.withLock { self.microphone }?.use(device: device)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Every two seconds: is each capture still delivering? A stalled one is rebuilt.
    ///
    /// A capture always delivers while it runs, silence included, so no blocks for
    /// `stallTimeout` is a dead capture and never a quiet meeting.
    private func startWatchdog() {
        let timeout = configuration.stallTimeout
        watchdog = Task.detached { [weak self] in
            var tapCheck = StallCheck(), micCheck = StallCheck()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                let (tap, microphone) = self.lock.withLock { (self.tap, self.microphone) }
                if let tap {
                    switch tapCheck.observe(tap.deliveredBuffers, timeout: timeout) {
                    case .stalled(let firstTime):
                        if firstTime { self.onHealth?(.others, false) }
                        self.rebuildTap()
                        // The new tap counts from zero.
                        tapCheck = StallCheck(healthy: false, last: 0)
                    case .recovered: self.onHealth?(.others, true)
                    case .fine: break
                    }
                }
                if let microphone {
                    switch micCheck.observe(microphone.deliveredBuffers, timeout: timeout) {
                    case .stalled(let firstTime):
                        if firstTime { self.onHealth?(.me, false) }
                        microphone.restart()
                        micCheck.restartWait()
                    case .recovered: self.onHealth?(.me, true)
                    case .fine: break
                    }
                }
            }
        }
    }

    /// Kills the others' capture the way a device change does — the tap stops delivering
    /// and nobody is told — so the recovery can be tested end to end (TESTING-MEETINGS.md,
    /// T3). The watchdog must notice, rebuild and pad the gap.
    public func simulateCaptureLoss() {
        lock.withLock { tap }?.stop()
    }

    /// A tap whose aggregate device died is not revived: a new one replaces it.
    private func rebuildTap() {
        let old = lock.withLock { () -> ProcessTap? in
            defer { tap = nil }
            return tap
        }
        old?.stop()
        tapRebuilds += 1
        do {
            try startTap()
        } catch {
            // The app may be between helpers; the next round tries again.
            lock.withLock { tap = old }
        }
    }

    /// Stops the captures, waits for the last segments and returns the transcript.
    public func stop() async -> Transcript {
        watchdog?.cancel()
        watchdog = nil
        appMicrophoneLoop?.cancel()
        appMicrophoneLoop = nil
        let (tap, microphone, feed) = lock.withLock { (self.tap, self.microphone, self.gatedFeed) }
        tap?.stop()
        microphone?.stop()
        feed?.flush()
        for transcriber in transcribers { await transcriber.finish() }
        lock.withLock {
            self.tap = nil
            self.microphone = nil
        }
        if let reservedLocale { _ = await AssetInventory.release(reservedLocale: reservedLocale) }
        return snapshot()
    }

    /// The others' audio so far, for a diarization pass during the meeting.
    public func othersAudioSoFar() -> [Float] { othersAudio.copy() }

    /// The others' audio kept for diarization, handed over once and then forgotten.
    public func takeOthersAudio() -> [Float] { othersAudio.take() }

    /// The transcript so far.
    public func snapshot() -> Transcript {
        lock.lock()
        defer { lock.unlock() }
        return transcript
    }

    public var diagnostics: [String] {
        let microphone = lock.withLock { self.microphone }
        let gated = lock.withLock { gatedFeed?.silencedSeconds } ?? 0
        return transcribers.map { "\($0.channel.rawValue): \($0.diagnostics)" }
            + [microphone.map { "mic: \($0.diagnostics) device=\($0.currentDevice.map(String.init) ?? "default")" } ?? "mic: none",
               "mic muted: \(String(format: "%.1f", gated)) s", "tap rebuilds: \(tapRebuilds)"]
    }

    /// Seconds of audio received per channel: a channel stuck at zero is a capture that
    /// never started, which is otherwise indistinguishable from a silent meeting.
    public var secondsCaptured: [Channel: Double] {
        Dictionary(transcribers.map { ($0.channel, $0.secondsFed) }, uniquingKeysWith: max)
    }

    private func record(_ segment: TranscriptSegment) {
        lock.lock()
        transcript.segments.append(segment)
        lock.unlock()
        onSegment?(segment)
    }
}

/// Whether a delivery counter is still moving.
struct StallCheck {
    enum Verdict: Equatable { case fine, recovered, stalled(firstTime: Bool) }

    private var last: Int
    private var since: ContinuousClock.Instant?
    private(set) var healthy: Bool

    init(healthy: Bool = true, last: Int = -1) {
        self.healthy = healthy
        self.last = last
    }

    /// Called every round with the counter's current value.
    mutating func observe(_ delivered: Int, timeout: Duration, now: ContinuousClock.Instant = .now) -> Verdict {
        defer { last = delivered }
        guard delivered == last else {
            since = nil
            if healthy { return .fine }
            healthy = true
            return .recovered
        }
        let stalledSince = since ?? now
        since = stalledSince
        guard stalledSince.duration(to: now) >= timeout else { return .fine }
        let firstTime = healthy
        healthy = false
        since = nil
        return .stalled(firstTime: firstTime)
    }

    /// After a restart, give the capture a full timeout before judging it again.
    mutating func restartWait() { since = nil }
}

/// A channel's loudness for display: the block's RMS on a speech-friendly scale, rising
/// at once and falling slowly, so the indicator moves with the voice instead of flickering.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float = 0

    var value: Float { lock.withLock { level } }

    func measure(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(data[0], 1, &rms, vDSP_Length(buffer.frameLength))
        // -50 dBFS → 0, -10 dBFS → 1.
        let decibels = 20 * log10(max(rms, 1e-6))
        let scaled = min(max((decibels + 50) / 40, 0), 1)
        lock.withLock { level = max(scaled, level * 0.82) }
    }
}

/// The microphone's blocks, held for `delay` seconds and then fed — or replaced by
/// silence of the same length when the gate was closed when the block was heard or when
/// it leaves. Silence, not nothing: the channels are aligned by counting what each was fed.
///
/// The delay is what makes a late mute safe: the app's state is read a few times a
/// second, so the words said between pressing mute and Quill noticing are still waiting
/// here when it notices. A block is fed only if the gate was open at both ends.
final class GatedFeed: @unchecked Sendable {
    private struct Pending {
        let buffer: AVAudioPCMBuffer
        let start: Double
        let mutedWhenHeard: Bool
    }

    private let gate: MicrophoneGate?
    private let delay: Double
    private let deliver: (AVAudioPCMBuffer, Double) -> Void
    private let lock = NSLock()
    private var pending: [Pending] = []
    private var silenced = 0.0

    init(gate: MicrophoneGate?, delay: Double, deliver: @escaping (AVAudioPCMBuffer, Double) -> Void) {
        self.gate = gate
        self.delay = gate == nil ? 0 : delay
        self.deliver = deliver
    }

    /// Seconds of the microphone replaced by silence so far.
    var silencedSeconds: Double { lock.withLock { silenced } }

    func push(_ buffer: AVAudioPCMBuffer, start: Double) {
        let ready: [Pending] = lock.withLock {
            pending.append(Pending(buffer: buffer, start: start, mutedWhenHeard: gate?.isMuted ?? false))
            let newest = start + Double(buffer.frameLength) / buffer.format.sampleRate
            let count = pending.prefix { newest - $0.start >= delay }.count
            defer { pending.removeFirst(count) }
            return Array(pending.prefix(count))
        }
        release(ready)
    }

    /// Feeds whatever is still waiting, through the gate as it is now.
    func flush() {
        let ready = lock.withLock { () -> [Pending] in
            defer { pending = [] }
            return pending
        }
        release(ready)
    }

    private func release(_ blocks: [Pending]) {
        let mutedNow = gate?.isMuted ?? false
        for block in blocks {
            if block.mutedWhenHeard || mutedNow {
                lock.withLock { silenced += Double(block.buffer.frameLength) / block.buffer.format.sampleRate }
                deliver(Self.silence(like: block.buffer), block.start)
            } else {
                deliver(block.buffer, block.start)
            }
        }
    }

    static func silence(like buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let silent = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return buffer }
        silent.frameLength = buffer.frameLength
        // A new buffer's memory is not guaranteed zeroed.
        let list = UnsafeMutableAudioBufferListPointer(silent.mutableAudioBufferList)
        for audio in list { if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) } }
        return silent
    }
}
