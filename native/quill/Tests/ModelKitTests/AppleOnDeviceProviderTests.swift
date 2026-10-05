#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Testing

@testable import ModelKit

@Suite("Apple on-device provider")
struct AppleOnDeviceProviderTests {

    /// Live tests run the real model: slow-ish, need Apple Intelligence on,
    /// and are meaningless on CI runners. Opt in with `MODELKIT_LIVE_APPLE=1`.
    static var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["MODELKIT_LIVE_APPLE"] == "1"
            && SystemLanguageModel.default.isAvailable
    }

    @Test("examples become real prompt/response turns after the instructions")
    func transcriptShape() {
        let request = GenerationRequest(model: AppleOnDeviceProvider.modelID, instructions: "Fix spelling.", input: "x",
                                        examples: [.init(input: "q tal", output: "¿Qué tal?")])
        let entries = Array(AppleOnDeviceProvider.transcript(for: request))

        #expect(entries.count == 3)
        if case .instructions = entries[0] {} else { Issue.record("first entry must be the instructions") }
        if case .prompt = entries[1] {} else { Issue.record("an example input must be a prompt turn") }
        if case .response = entries[2] {} else { Issue.record("an example output must be a response turn") }
    }

    @Test("availability reasons map one to one")
    func availabilityMapping() {
        #expect(AppleOnDeviceProvider.map(.available) == .available)
        #expect(AppleOnDeviceProvider.map(.unavailable(.deviceNotEligible)) == .unavailable(.deviceNotEligible))
        #expect(AppleOnDeviceProvider.map(.unavailable(.appleIntelligenceNotEnabled)) == .unavailable(.appleIntelligenceDisabled))
        #expect(AppleOnDeviceProvider.map(.unavailable(.modelNotReady)) == .unavailable(.modelNotReady))
    }

    @Test("an unknown model id is rejected without touching the model")
    func unknownModel() async {
        let outcome = await collect(AppleOnDeviceProvider().stream(GenerationRequest(model: "gpt", instructions: "i", input: "x")))
        #expect(outcome.error?.code == .invalidRequest)
    }

    @Test("rewrites Spanish text on this Mac", .enabled(if: liveEnabled))
    func liveRewrite() async throws {
        let request = GenerationRequest(
            model: AppleOnDeviceProvider.modelID,
            instructions: "Corrige la ortografía del texto del usuario. Devuelve solo el texto corregido.",
            input: "q tal estas? ya e llegado a casa",
            options: GenerationOptions(temperature: 0))
        let outcome = await collect(AppleOnDeviceProvider().stream(request))

        #expect(outcome.error == nil)
        let text = try #require(outcome.result?.text)
        #expect(!text.isEmpty)
        #expect(outcome.deltas.joined() == text, "deltas must add up to the final text")
    }

    @Test("cancelling a live generation throws .cancelled from generate()", .enabled(if: liveEnabled))
    func liveCancellation() async {
        let request = GenerationRequest(model: AppleOnDeviceProvider.modelID, instructions: "Escribe un texto largo.",
                                        input: "Cuenta la historia de Roma en 2000 palabras.")
        let consumer = Task { () -> ProviderError? in
            do { _ = try await AppleOnDeviceProvider().generate(request); return nil }
            catch let error as ProviderError { return error }
            catch { return ProviderError(.server, "foreign error escaped: \(type(of: error))") }
        }
        try? await Task.sleep(for: .milliseconds(300))
        consumer.cancel()

        #expect(await consumer.value?.code == .cancelled)
    }
}
#endif
