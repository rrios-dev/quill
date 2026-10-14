import AVFAudio
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
public final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let echoCancellation: Bool
    private let queue = DispatchQueue(label: "dev.rrios.quill.listen.microphone")
    private let lock = NSLock()
    private var buffers = 0
    private var restarts = 0
    private var format: AVAudioFormat?
    private var voiceProcessing = false
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var observer: NSObjectProtocol?
    private var stopped = false

    public init(echoCancellation: Bool = true) {
        self.echoCancellation = echoCancellation
    }

    /// Blocks delivered so far, restarts, and the format they came in: a microphone that
    /// opens but never delivers is otherwise indistinguishable from a silent user.
    public var diagnostics: String {
        lock.lock()
        defer { lock.unlock() }
        let described = format.map { "\($0.sampleRate) Hz \($0.channelCount) ch" } ?? "none"
        return "buffers=\(buffers) restarts=\(restarts) format=\(described) vp=\(voiceProcessing) running=\(engine.isRunning)"
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
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.restart() }
        }
        try queue.sync { try configureAndStart() }
    }

    /// Rebuilds the tap with whatever format the device has now, and starts again.
    /// Called on a configuration change and by the session's watchdog.
    public func restart() {
        queue.async { [self] in
            guard !stopped else { return }
            lock.lock()
            restarts += 1
            lock.unlock()
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            // The device may still be settling (a Bluetooth headset changing profile):
            // retry a few times before giving up until the next change.
            for attempt in 0..<5 {
                if (try? configureAndStart()) != nil { return }
                Thread.sleep(forTimeInterval: 0.3 * Double(attempt + 1))
            }
        }
    }

    private func configureAndStart() throws {
        let input = engine.inputNode
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
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ListenError.microphoneUnavailable
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            self.buffers += 1
            self.format = buffer.format
            self.lock.unlock()
            guard let copy = buffer.copied() else { return }
            self.onBuffer?(copy)
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        queue.sync {
            stopped = true
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
}
