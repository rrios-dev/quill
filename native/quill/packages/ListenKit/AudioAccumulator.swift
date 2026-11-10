import AVFAudio
import Accelerate
import Foundation

/// Keeps one channel's audio **in memory only**, as 16 kHz mono samples, until the
/// meeting ends: telling voices apart works best over the whole meeting, and no audio
/// may touch the disk. Released the moment `take()` hands the samples over.
///
/// Kept as 16-bit samples, handed out as floats: an hour is 115 MB instead of 230 MB
/// (EFFICIENCY.md E2). Sixteen bits is what the bench's recordings and the diarizer's
/// training audio carry; the bench's gate is unchanged by it.
public final class AudioAccumulator: @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    private let lock = NSLock()
    private var samples: [Int16] = []
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
        samples.append(contentsOf: Self.quantized(UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength))))
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
        return Self.expanded(samples[...])
    }

    /// A copy of the samples between two moments of the session: one sentence's audio,
    /// without copying the meeting.
    public func copy(from start: Double, to end: Double) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let first = max(0, Int(start * Self.sampleRate)), last = min(samples.count, Int(end * Self.sampleRate))
        return last > first ? Self.expanded(samples[first..<last]) : []
    }

    /// Hands the samples over and forgets them.
    public func take() -> [Float] {
        lock.lock()
        let taken = samples
        samples = []
        lock.unlock()
        return Self.expanded(taken[...])
    }

    public var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / Self.sampleRate
    }

    static func quantized(_ floats: UnsafeBufferPointer<Float>) -> [Int16] {
        guard let base = floats.baseAddress, !floats.isEmpty else { return [] }
        var scaled = [Float](repeating: 0, count: floats.count)
        var scale = Float(Int16.max), low: Float = -Float(Int16.max), high = Float(Int16.max)
        vDSP_vsmul(base, 1, &scale, &scaled, 1, vDSP_Length(floats.count))
        vDSP_vclip(scaled, 1, &low, &high, &scaled, 1, vDSP_Length(floats.count))
        var result = [Int16](repeating: 0, count: floats.count)
        vDSP_vfixr16(scaled, 1, &result, 1, vDSP_Length(floats.count))
        return result
    }

    static func expanded(_ ints: ArraySlice<Int16>) -> [Float] {
        guard !ints.isEmpty else { return [] }
        var result = [Float](repeating: 0, count: ints.count)
        ints.withUnsafeBufferPointer { source in
            vDSP_vflt16(source.baseAddress!, 1, &result, 1, vDSP_Length(ints.count))
        }
        var scale = 1 / Float(Int16.max)
        vDSP_vsmul(result, 1, &scale, &result, 1, vDSP_Length(result.count))
        return result
    }
}
