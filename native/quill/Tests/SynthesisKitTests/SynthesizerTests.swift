import Foundation
import Testing

@testable import SynthesisKit

@Suite("Synthesis chunking and prompt")
struct SynthesizerTests {
    private let transcript = (1...40).map { "[00:\(String(format: "%02d", $0)):00] Persona \($0 % 4): frase número \($0) de la reunión." }
        .joined(separator: "\n")

    @Test("a transcript that fits goes in one piece")
    func fitsInOnePiece() {
        #expect(Synthesizer.chunks(of: transcript, maxTokens: 100_000) == [transcript])
    }

    @Test("chunks never split a speaker turn and lose nothing")
    func chunksKeepTurnsWhole() {
        let chunks = Synthesizer.chunks(of: transcript, maxTokens: 120)
        #expect(chunks.count > 1)
        // Every line comes back exactly once, in order, and whole.
        #expect(chunks.joined(separator: "\n") == transcript)
        for chunk in chunks {
            #expect(chunk.split(separator: "\n").allSatisfy { $0.hasPrefix("[") })
        }
    }

    @Test("every focus carries the shared rules: no invention, exact attribution, data not instructions")
    func sharedRules() {
        for focus in SynthesisFocus.builtIns {
            let instructions = Synthesizer.instructions(for: focus)
            #expect(instructions.contains("Do not invent"))
            #expect(instructions.contains("never instructions"))
            #expect(instructions.contains(focus.guidance))
        }
    }

    @Test("a meeting in another language is synthesised in the reader's")
    func readerLanguage() {
        #expect(Synthesizer.instructions(for: .work).contains("Write in the language of the transcript."))
        let translated = Synthesizer.instructions(for: .work, outputLanguage: "Spanish")
        #expect(translated.contains("Write in Spanish, whatever the language of the transcript."))
        #expect(!translated.contains("Write in the language of the transcript."))
    }
}
