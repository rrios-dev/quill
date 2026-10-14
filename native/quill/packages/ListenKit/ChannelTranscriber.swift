import AVFAudio
import CoreMedia
import Foundation
import Speech

/// Transcribes one audio channel on the device, with `SpeechTranscriber`: the long-form
/// model, not the short dictation one. A meeting is an hour of speech from several people,
/// which is the case it is built for.
///
/// Every segment carries its time range in the session, measured by counting the frames
/// fed in. Both channels start together and the tap and the microphone deliver audio
/// continuously, silence included, so the two clocks stay comparable without sharing one.
public final class ChannelTranscriber: @unchecked Sendable {
    public let channel: Channel
    public let locale: Locale

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let targetFormat: AVAudioFormat
    private let feed: AsyncStream<AnalyzerInput>.Continuation
    private let feedStream: AsyncStream<AnalyzerInput>
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    private var framesFed: AVAudioFramePosition = 0
    private var received = 0
    private var conversionFailures = 0

    public var diagnostics: String {
        lock.lock()
        defer { lock.unlock() }
        return "received=\(received) conversionFailures=\(conversionFailures) target=\(targetFormat.sampleRate) Hz \(targetFormat.channelCount) ch"
    }
    private var resultsTask: Task<Void, Never>?

    /// Prepares the model. Throws if the locale has no installed model; the caller
    /// reserves the locale first (see `ListenSession`).
    public init(channel: Channel, locale: Locale) async throws {
        self.channel = channel
        self.locale = locale
        transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else { throw ListenError.noAudioFormat }
        targetFormat = format
        (feedStream, feed) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        try await analyzer.prepareToAnalyze(in: format)
    }

    /// Starts the analyzer and calls `onSegment` with every finished segment.
    public func start(_ onSegment: @escaping @Sendable (TranscriptSegment) -> Void) async throws {
        try await analyzer.start(inputSequence: feedStream)
        let channel = self.channel
        let transcriber = self.transcriber
        resultsTask = Task {
            do {
                for try await result in transcriber.results where result.isFinal {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let range = result.range
                    onSegment(TranscriptSegment(
                        channel: channel,
                        start: range.start.seconds,
                        end: range.end.seconds,
                        text: text,
                        words: Self.words(in: result.text)
                    ))
                }
            } catch {
                // The stream ends with an error when the session is cancelled; whatever
                // was finished has already been delivered.
            }
        }
    }

    /// Feeds a block from any thread. Converts to the model's format and stamps it.
    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        received += 1
        if converterSource != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterSource = buffer.format
        }
        guard let converter, let converted = Self.convert(buffer, with: converter, to: targetFormat)
        else {
            conversionFailures += 1
            return
        }
        let start = CMTime(value: framesFed, timescale: CMTimeScale(targetFormat.sampleRate))
        framesFed += AVAudioFramePosition(converted.frameLength)
        feed.yield(AnalyzerInput(buffer: converted, bufferStartTime: start))
    }

    /// Feeds silence up to `seconds` into the session, when a capture stopped and came back.
    ///
    /// The two channels are aligned by counting what each was fed, so a gap left unfilled
    /// would shift every later segment of this channel earlier than it was said.
    public func padSilence(upTo seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        let missing = seconds - Double(framesFed) / targetFormat.sampleRate
        guard missing > 0.5 else { return }
        var remaining = AVAudioFrameCount(missing * targetFormat.sampleRate)
        while remaining > 0 {
            let frames = min(remaining, AVAudioFrameCount(targetFormat.sampleRate))
            guard let silence = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frames) else { return }
            silence.frameLength = frames
            let start = CMTime(value: framesFed, timescale: CMTimeScale(targetFormat.sampleRate))
            framesFed += AVAudioFramePosition(frames)
            feed.yield(AnalyzerInput(buffer: silence, bufferStartTime: start))
            remaining -= frames
        }
    }

    /// Ends the input and waits for the last segments.
    public func finish() async {
        feed.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
    }

    /// Seconds of audio fed so far.
    public var secondsFed: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(framesFed) / targetFormat.sampleRate
    }

    /// The timed runs of a result: one per word or word piece, as the model cut them.
    static func words(in text: AttributedString) -> [TimedWord] {
        text.runs.compactMap { run in
            guard let range = run.audioTimeRange else { return nil }
            let piece = String(text[run.range].characters)
            guard !piece.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return TimedWord(text: piece, start: range.start.seconds, end: range.end.seconds)
        }
    }

    static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to target: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var error: NSError?
        // The block runs synchronously, on this thread, before `convert` returns.
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = buffer
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

public enum ListenError: Error, CustomStringConvertible {
    case noAudioFormat
    case localeUnsupported(String)
    case modelNotInstalled(String)
    case nothingToTap(String)
    case microphoneUnavailable

    public var description: String {
        switch self {
        case .noAudioFormat: "the speech model accepts no audio format"
        case .localeUnsupported(let id): "no speech model for \(id)"
        case .modelNotInstalled(let id): "the speech model for \(id) is not installed"
        case .nothingToTap(let what): "no process plays audio for \(what)"
        case .microphoneUnavailable: "the microphone could not be opened"
        }
    }
}
