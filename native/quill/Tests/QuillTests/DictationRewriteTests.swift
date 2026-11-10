import AppCore
import CoreGraphics
import Foundation
import SelectionKit
import Testing
import VoiceKit

@testable import Quill

/// Dictate and rewrite (EFFICIENCY.md E8): what was said reaches the rewrite, corrected
/// with Ámbar's dictionary, for the app that was in front when it began.
@MainActor
@Suite("Dictate and rewrite", .serialized)
struct DictationRewriteTests {
    /// A session that says what it is told to, as the engine would.
    final class ScriptedSession: TranscriptionSession, @unchecked Sendable {
        let fragments: [TranscriptFragment]
        let final: String
        var failPrepare: DictationEngineError?
        private(set) var cancelled = false
        private(set) var contextualStrings: [String]

        init(fragments: [String], final: String, contextualStrings: [String] = []) {
            self.fragments = fragments.map { TranscriptFragment(text: $0, isVolatile: true) }
            self.final = final
            self.contextualStrings = contextualStrings
        }

        func prepare() async throws { if let failPrepare { throw failPrepare } }
        private(set) var started = false
        func start() async throws -> AsyncStream<TranscriptFragment> {
            started = true
            let (stream, continuation) = AsyncStream<TranscriptFragment>.makeStream()
            for fragment in fragments { continuation.yield(fragment) }
            continuation.finish()
            return stream
        }
        func finish() async throws -> Transcript { Transcript(text: final, mode: .live) }
        func cancel() async { cancelled = true }
        func setDeviceChangeHandler(_ handler: @escaping @Sendable () -> Void) async {}
        func setSessionLimitHandler(_ handler: @escaping @Sendable () -> Void) async {}
    }

    private let mail = AppIdentity(pid: 42, bundleIdentifier: "com.apple.mail")
    private var target: DictationTarget {
        DictationTarget(app: mail, selected: "", editability: .editable, caret: CGRect(x: 100, y: 500, width: 1, height: 16))
    }

    private func dictionary(_ entries: [DictionaryEntry]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: url)
        return url
    }

    @Test("held: the words show as they are said; done, what was said goes to the rewrite, corrected, for where the cursor was")
    func dictatesAndDelivers() async throws {
        let file = try dictionary([DictionaryEntry(id: UUID(), written: "Kubernetes", heard: ["cuber netes"],
                                                   uses: 3, lastUsedAt: Date(), addedAt: Date())])
        defer { try? FileManager.default.removeItem(at: file) }
        var made: ScriptedSession?
        let model = DictationRewrite(makeSession: { strings in
            let session = ScriptedSession(fragments: ["mañana subimos a cuber"], final: "mañana subimos a cuber netes",
                                          contextualStrings: strings)
            made = session
            return session
        }, dictionaryFile: { file })
        var panel: [Bool] = []
        var delivered: (String, DictationTarget)?
        model.showPanel = { panel.append($0) }
        model.deliver = { delivered = ($0, $1) }

        model.arm(for: target)
        #expect(model.phase == .armed)
        #expect(panel.isEmpty, "nothing shows while it may still be a tap")
        #expect(made?.contextualStrings == ["Kubernetes"], "Ámbar's words bias the engine")
        await model.startListening()
        #expect(model.phase == .listening)
        #expect(model.usesAmbarDictionary)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.text == "mañana subimos a cuber")

        await model.finish()
        #expect(delivered?.0 == "mañana subimos a Kubernetes")
        #expect(delivered?.1 == target, "the words go where the cursor was when the keys went down")
        #expect(model.phase == .idle)
        #expect(panel == [true, false])
    }

    @Test("what the picker rewrites is inserted over what the field had selected, with nothing to lose in formatting")
    func captureForTheCursor() {
        let capture = target.capture(of: "nos vemos el jueves")
        #expect(capture.text == "nos vemos el jueves")
        #expect(capture.fieldSelection == "")
        #expect(capture.formatting == .plain, "no 'formatting could not be checked' warning on new words")
        #expect(capture.bounds == target.caret, "the picker opens where the words were said")
    }

    @Test("a tap after all: the armed model is let go, the microphone never opened")
    func disarmed() async {
        var session: ScriptedSession?
        let model = DictationRewrite(makeSession: { _ in
            let made = ScriptedSession(fragments: [], final: "x")
            session = made
            return made
        }, dictionaryFile: { nil })
        var panel: [Bool] = []
        model.showPanel = { panel.append($0) }
        model.arm(for: target)
        await model.disarm()
        #expect(session?.cancelled == true)
        #expect(session?.started == false)
        #expect(model.phase == .idle)
        #expect(panel.isEmpty)
    }

    @Test("without Ámbar it dictates all the same, with no dictionary")
    func withoutAmbar() async {
        let model = DictationRewrite(makeSession: { _ in ScriptedSession(fragments: [], final: "hola") },
                                     dictionaryFile: { nil })
        var delivered: String?
        model.deliver = { text, _ in delivered = text }
        await model.toggle(target: target)
        #expect(!model.usesAmbarDictionary)
        await model.toggle(target: target)
        #expect(delivered == "hola")
    }

    @Test("cancelling or saying nothing delivers nothing, and the shortcut is told")
    func nothingDelivered() async {
        let model = DictationRewrite(makeSession: { _ in ScriptedSession(fragments: [], final: "  ") }, dictionaryFile: { nil })
        var deliveries = 0, ended = 0
        model.deliver = { _, _ in deliveries += 1 }
        model.onEnded = { ended += 1 }
        await model.toggle(target: target)
        await model.cancel()
        #expect(model.phase == .idle)
        await model.toggle(target: target)
        await model.toggle(target: target)
        #expect(deliveries == 0, "silence is not a text to rewrite")
        #expect(ended == 2)
    }

    @Test("a missing speech model says what to do; the next hold tries again")
    func missingModel() async {
        var attempts = 0
        let model = DictationRewrite(makeSession: { _ in
            attempts += 1
            let session = ScriptedSession(fragments: [], final: "")
            session.failPrepare = .modelNotInstalled
            return session
        }, dictionaryFile: { nil })
        model.arm(for: target)
        await model.startListening()
        guard case .failed(let message) = model.phase else {
            Issue.record("expected a failure, got \(model.phase)")
            return
        }
        #expect(message.contains("Dictado") || message.contains("Dictation"))
        model.arm(for: target)
        #expect(attempts == 2, "a failure does not stick: the shortcut starts again")
    }

    /// The real engine on real speech: a sentence spoken by the system's Spanish voice,
    /// heard from a file through the same path as the microphone, corrected with a
    /// dictionary as Ámbar writes it.
    @Test("the real engine dictates a spoken Spanish sentence and Ámbar's words are applied", .enabled(
        if: ProcessInfo.processInfo.environment["AMBAR_SKIP_SPEECH_TESTS"] == nil,
        "needs the Spanish speech model installed"))
    func realEngine() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Mónica", "-o", audio.path, "Mañana revisamos el presupuesto con el equipo de producto."]
        try say.run()
        say.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: audio) }
        let file = try dictionary([DictionaryEntry(id: UUID(), written: "PRESUPUESTO-Q4", heard: ["presupuesto"],
                                                   uses: 1, lastUsedAt: Date(), addedAt: Date())])
        defer { try? FileManager.default.removeItem(at: file) }
        let model = DictationRewrite(makeSession: { strings in
            SpeechSession(locale: Locale(identifier: "es_ES"), mode: .live, source: .file(audio), contextualStrings: strings)
        }, dictionaryFile: { file })
        var delivered: String?
        var loudest: Float = 0
        model.deliver = { text, _ in delivered = text }
        model.arm(for: target)
        await model.startListening()
        #expect(model.phase == .listening)
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            loudest = max(loudest, model.level)
        }
        await model.finish()
        #expect(loudest > 0.3, "the meter moved with the voice: \(loudest)")
        let text = try #require(delivered)
        #expect(text.lowercased().contains("mañana"), "heard: \(text)")
        #expect(text.contains("PRESUPUESTO-Q4"), "Ámbar's word was not applied: \(text)")
    }
}
