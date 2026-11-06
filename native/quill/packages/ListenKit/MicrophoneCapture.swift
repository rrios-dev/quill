import AVFAudio
import CoreAudio
import Accelerate
import Foundation

/// The user's own voice, from the microphone.
///
/// With voice processing on, the system cancels what the speakers play from what the
/// microphone hears. Without it, a meeting on speakers reaches the transcript twice:
/// once from the app's output, once through the room as if the user had said it.
///
/// **Voice processing only on speakers.** The same unit ducks every other app's audio
/// while it runs, and the meeting is other audio: on 2026-10-08 the owner heard the call
/// drop to a whisper in their AirPods for as long as Quill listened. With headphones
/// there is no echo to cancel, so it stays off (`OutputRoute`); on speakers it is needed,
/// and ducking is set to the minimum the system allows.
///
/// **It restarts itself when the device changes.** Measured on 2026-10-08 with AirPods:
/// opening their microphone switches them to the call profile, the engine is
/// reconfigured, and `AVAudioEngine` stops without an error — `start()` had returned
/// fine, no block ever arrived. Joining the call in Teams does the same later. The
/// engine posts `AVAudioEngineConfigurationChange`; nobody listened, so "me" went silent
/// for the rest of the meeting. Now every change rebuilds the tap with the new format.
///
/// **A device that goes away takes the engine with it.** Reported 2026-11-06: a headset
/// dropped mid-call, came back, and "me" never did. Reproduced with a private aggregate
/// device destroyed and created again (`MicrophoneReconnectTests`): the same engine kept
/// the dead device, so falling back to the default never happened; and after choosing a
/// device the input node still reports the default's format, so a tap in it heard
/// nothing — "me" silent — or, restarted, raised an exception that ends the process. Now
/// the tap takes the device's own format, a failed start, the watchdog and a change of
/// device each get a new engine, and a device appearing retries the one the meeting app
/// records from.
public final class MicrophoneCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let echoCancellation: Bool
    private let queue = DispatchQueue(label: "dev.rrios.quill.listen.microphone")
    private let lock = NSLock()
    private var buffers = 0
    private var restarts = 0
    private var format: AVAudioFormat?
    private var voiceProcessing = false
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var observer: NSObjectProtocol?
    private var started = false
    private var stopped = false
    private var channelPeaks: [Float] = []
    private var device: AudioDeviceID?
    /// The device the engine actually records from: `device` when it could be chosen,
    /// else nil (the default).
    private var boundDevice: AudioDeviceID?
    private var devicesListener: AudioObjectPropertyListenerBlock?

    public init(echoCancellation: Bool = true) {
        self.echoCancellation = echoCancellation
    }

    /// Blocks delivered so far, restarts, and the format they came in: a microphone that
    /// opens but never delivers is otherwise indistinguishable from a silent user.
    public var diagnostics: String {
        lock.lock()
        defer { lock.unlock() }
        let described = format.map { "\($0.sampleRate) Hz \($0.channelCount) ch layout=\($0.channelLayout.map { String($0.layoutTag, radix: 16) } ?? "none")" } ?? "none"
        let peaks = channelPeaks.map { String(format: "%.0f", 20 * log10(max($0, 1e-6))) }.joined(separator: "/")
        let bound = boundDevice.map(String.init) ?? "default"
        return "buffers=\(buffers) restarts=\(restarts) format=\(described) vp=\(voiceProcessing) running=\(engine.isRunning) bound=\(bound) peakRMSdB=\(peaks)"
    }

    /// The input device this capture records from: the one the meeting app uses, else the
    /// system default (nil).
    public var currentDevice: AudioDeviceID? { lock.withLock { device } }

    /// Records from `device` from now on (nil: the system default). The meeting app's
    /// microphone, not the default: on the owner's Mac the default is a webcam across the
    /// desk while the call runs on a headset, and "me" came out empty (2026-10-30).
    public func use(device: AudioDeviceID?) {
        guard lock.withLock({ self.device }) != device else { return }
        lock.withLock { self.device = device }
        restart()
    }

    /// Blocks delivered so far; the session's watchdog reads it to tell a stalled
    /// microphone from a quiet one.
    public var deliveredBuffers: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffers
    }

    public func start(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        self.onBuffer = onBuffer
        try queue.sync {
            observeConfiguration()
            try configureAndStart()
            started = true
            // On the queue, so `stop` cannot run between the start and the registration.
            listenForDevices()
        }
    }

    /// Starts again on a new engine, with whatever device there is now. Called by the
    /// session's watchdog and when the device changes: an engine that lost its device
    /// keeps it, and falling back to the default never happens.
    public func restart() { recover(freshEngine: true) }

    /// Rebuilds the tap with whatever format the device has now, and starts again; on a
    /// new engine if this one will not start. A configuration change keeps the engine:
    /// every start on a new one posts a change of its own, so a new engine per change
    /// never settles (measured 2026-11-06).
    private func recover(freshEngine: Bool) {
        queue.async { [self] in
            // Before `start`, a change of device is only remembered: `start` uses it.
            guard started, !stopped else { return }
            lock.withLock { restarts += 1 }
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            if freshEngine { replaceEngine() }
            // The device may still be settling (a Bluetooth headset changing profile):
            // retry a few times, each on a new engine, before giving up until the next
            // change or the watchdog.
            for attempt in 0..<5 {
                if (try? configureAndStart()) != nil { return }
                Thread.sleep(forTimeInterval: 0.3 * Double(attempt + 1))
                replaceEngine()
            }
        }
    }

    /// On the capture queue.
    private func replaceEngine() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        let fresh = AVAudioEngine()
        lock.withLock { engine = fresh }
        observeConfiguration()
    }

    /// On the capture queue.
    private func observeConfiguration() {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // `recover` hops onto the capture queue itself.
            self?.recover(freshEngine: false)
        }
    }

    /// A device appearing may be the one the meeting app records from coming back with
    /// the id it had, so the meeting app's own switch is never seen: retry it. Only when
    /// that device is there again: any other device coming or going changes the list too.
    /// On the capture queue.
    private func listenForDevices() {
        var address = Self.devicesAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let (wanted, bound) = self.lock.withLock { (self.device, self.boundDevice) }
            if let wanted, wanted != bound, Self.isAlive(wanted) { self.restart() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == noErr {
            devicesListener = listener
        }
    }

    private static func isAlive(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    private static let devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    private func configureAndStart() throws {
        let input = engine.inputNode
        var bound: AudioDeviceID?
        if let device = lock.withLock({ self.device }) {
            // A device that cannot be chosen (gone, or refused under voice processing)
            // leaves the default: better the wrong microphone than none.
            if (try? input.auAudioUnit.setDeviceID(device)) != nil { bound = device }
        }
        lock.withLock { boundDevice = bound }
        // Decided on every start: a restart is usually the output device changing.
        let wanted = echoCancellation && OutputRoute.current() == .speakers
        if input.isVoiceProcessingEnabled != wanted {
            try input.setVoiceProcessingEnabled(wanted)
        }
        if wanted {
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min
            )
        }
        lock.withLock { voiceProcessing = wanted }
        // Without voice processing, the device's own format. After `setDeviceID` the
        // node's output format is still the default microphone's — 44.1 kHz for a
        // headset at 16 kHz in its call profile — and a tap in it receives nothing, or
        // on a restarted engine raises an Objective-C exception ("format mismatch")
        // Swift cannot catch (measured 2026-11-06). Voice processing has its own output
        // format, which is the one to tap.
        let format = wanted ? input.outputFormat(forBus: 0) : input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ListenError.microphoneUnavailable
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            self.buffers += 1
            self.format = buffer.format
            if let data = buffer.floatChannelData {
                let count = Int(buffer.format.channelCount)
                if self.channelPeaks.count != count { self.channelPeaks = [Float](repeating: 0, count: count) }
                for channel in 0..<count {
                    var rms: Float = 0
                    vDSP_rmsqv(data[channel], 1, &rms, vDSP_Length(buffer.frameLength))
                    self.channelPeaks[channel] = max(self.channelPeaks[channel], rms)
                }
            }
            self.lock.unlock()
            guard let copy = buffer.copied() else { return }
            self.onBuffer?(copy)
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        let listener: AudioObjectPropertyListenerBlock? = queue.sync {
            stopped = true
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            defer { devicesListener = nil }
            return devicesListener
        }
        // Off the queue: removing waits for a callback in flight, which runs on it.
        if let listener {
            var address = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }
}
