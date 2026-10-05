import Foundation
import ModelKit
import Testing

@testable import RewriteKit

@Suite("Readiness labels")
struct ReadinessTests {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../tools/QuillBench/data/readiness.json").standardizedFileURL
    let onDevice = ModelSelection(provider: "apple.on-device", model: "system")

    @Test("canonical identities as the bench keys them")
    func identities() {
        #expect(ModelIdentity.canonical(onDevice, osMajor: 26) == "apple/on-device@26")
        #expect(ModelIdentity.canonical(ModelSelection(provider: "openai", model: "gpt-x")) == "openai/gpt-x")
        #expect(ModelIdentity.canonical(ModelSelection(provider: "openrouter", model: "vendor/model")) == "vendor/model")
    }

    @Test("the shipped built-ins read their committed labels; an edit reads not evaluated (edited)")
    func committedLabels() throws {
        let index = try ReadinessIndex(data: Data(contentsOf: Self.file))
        let composer = try PromptComposer()
        let gemini = ModelSelection(provider: "openrouter", model: "google/gemini-3.8-flash")
        for builtIn in BuiltInProfile.shipped {
            let profile = try BuiltInProfiles.make(builtIn, language: "es")
            #expect(index.label(for: profile, model: onDevice, contextTokens: 4_096, composer: composer, osMajor: 27)
                    == .notRecommended, "\(builtIn)")
            #expect(index.label(for: profile, model: gemini, contextTokens: 1_000_000, composer: composer)
                    == .worksWell, "\(builtIn): confirmed on the holdout (P1-T9)")
            var edited = profile
            edited.guidance += " Edited."
            #expect(index.label(for: edited, model: onDevice, contextTokens: 4_096, composer: composer, osMajor: 27)
                    == .notEvaluatedEdited, "\(builtIn)")
        }
        let mine = Profile(name: "Mine", symbol: "pencil", settings: ProfileSettings(scope: .rewrite))
        #expect(index.label(for: mine, model: onDevice, contextTokens: 4_096, composer: composer, osMajor: 27) == .notEvaluated)
        // macOS 26 measured the profiles whose prompt has not changed since; Work and
        // Formal were tuned afterwards (P1-T9), so their new prompts were not measured there.
        for builtIn in [BuiltInProfile.spelling, .friends] {
            let profile = try BuiltInProfiles.make(builtIn, language: "es")
            #expect(index.label(for: profile, model: onDevice, contextTokens: 4_096, composer: composer, osMajor: 26)
                    == .notRecommended, "\(builtIn)")
        }
        let work = try BuiltInProfiles.make(.work, language: "es")
        #expect(index.label(for: work, model: onDevice, contextTokens: 4_096, composer: composer, osMajor: 26) == .notEvaluated)
        // Another macOS major is another model: nothing measured yet.
        let spelling = try BuiltInProfiles.make(.spelling, language: "es")
        #expect(index.label(for: spelling, model: onDevice, contextTokens: 4_096, composer: composer, osMajor: 28) == .notEvaluated)
    }

    @Test("a verdict measured with older guards is not reused")
    func evaluationVersion() throws {
        let index = try ReadinessIndex(data: Data(contentsOf: Self.file))
        let composer = try PromptComposer()
        let hash = composer.promptHash(profile: try BuiltInProfiles.make(.work, language: "es"), strategy: .compact)
        #expect(index.label(promptHash: hash, model: onDevice, osMajor: 27) == .notRecommended)
        #expect(index.label(promptHash: hash, model: onDevice, evaluationVersion: 1, osMajor: 27) == .notEvaluated)
    }

    @Test("the batch gives every model the label it would get alone")
    func batchMatchesSingle() throws {
        let index = try ReadinessIndex(data: Data(contentsOf: Self.file))
        let composer = try PromptComposer()
        let models: [(selection: ModelSelection, contextTokens: Int?)] = [
            (ModelSelection(provider: "openrouter", model: "google/gemini-3.8-flash"), 1_000_000),
            (ModelSelection(provider: "openrouter", model: "openai/gpt-6-luna"), 400_000),
            (ModelSelection(provider: "openrouter", model: "vendor/unmeasured"), 128_000),
            (onDevice, 4_096),
        ]
        for builtIn in BuiltInProfile.shipped {
            var profile = try BuiltInProfiles.make(builtIn, language: "es")
            for edited in [false, true] {
                if edited { profile.guidance += " Edited." }
                let batch = index.labels(for: profile, models: models, composer: composer, osMajor: 27)
                for model in models {
                    #expect(batch[model.selection] == index.label(for: profile, model: model.selection,
                                                                  contextTokens: model.contextTokens, composer: composer, osMajor: 27),
                            "\(builtIn) \(model.selection) edited \(edited)")
                }
            }
        }
    }
}
