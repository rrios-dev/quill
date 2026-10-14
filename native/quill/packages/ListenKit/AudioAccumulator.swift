import AVFAudio
import Foundation

/// Keeps one channel's audio **in memory only**, as 16 kHz mono samples, until the
/// meeting ends: telling voices apart works best over the whole meeting, and no audio
/// may touch the disk. An hour is a couple of hundred megabytes of RAM, released the
/// moment `take()` hands the samples over.
public final class AudioAccumulator: @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioAccumulator.sampleRate,
        channels: 1,
        interleaved: false
    )!

    public init() {}

    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if converterSource != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterSource = buffer.format
        }
        guard let converter,
              let converted = ChannelTranscriber.convert(buffer, with: converter, to: target),
              let data = converted.floatChannelData else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength)))
    }

    /// Zeros up to `seconds`, so diarization times stay aligned with the transcript's
    /// after the capture stopped and came back.
    public func padSilence(upTo seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        let missing = Int(seconds * Self.sampleRate) - samples.count
        if missing > Int(Self.sampleRate / 2) { samples.append(contentsOf: repeatElement(0, count: missing)) }
    }

    /// A copy of what was kept so far, keeping it: for telling voices apart while the
    /// meeting goes on.
    public func copy() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// Hands the samples over and forgets them.
    public func take() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let taken = samples
        samples = []
        return taken
    }

    public var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / Self.sampleRate
    }
}
