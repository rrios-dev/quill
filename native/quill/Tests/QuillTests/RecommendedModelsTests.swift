import Foundation
import ModelKit
import RewriteKit
import Testing

@testable import Quill

/// README Q6 and `readiness.json` agree (PLAN P1-T10's Accept).
@Suite("Recommended models")
@MainActor
struct RecommendedModelsTests {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../tools/QuillBench/data/readiness.json").standardizedFileURL

    @Test("every recommended model works well for at least one built-in")
    func recommendedAreMeasured() throws {
        let index = try ReadinessIndex(data: Data(contentsOf: Self.file))
        let composer = try PromptComposer()
        let builtIns = try BuiltInProfile.shipped.map { try BuiltInProfiles.make($0, language: "es") }
        for (provider, models) in AppEnvironment.recommendedModels {
            for model in models {
                let selection = ModelSelection(provider: provider, model: model)
                let labels = builtIns.map {
                    index.label(for: $0, model: selection, contextTokens: 1_000_000, composer: composer)
                }
                #expect(labels.contains(.worksWell), "\(provider)/\(model)")
            }
        }
    }

    @Test("every built-in has a recommended model it works well on (BENCH §1.1)")
    func everyBuiltInIsCovered() throws {
        let index = try ReadinessIndex(data: Data(contentsOf: Self.file))
        let composer = try PromptComposer()
        let recommended = AppEnvironment.recommendedModels["openrouter"] ?? []
        for builtIn in BuiltInProfile.shipped {
            let profile = try BuiltInProfiles.make(builtIn, language: "es")
            let covered = recommended.contains {
                index.label(for: profile, model: ModelSelection(provider: "openrouter", model: $0),
                            contextTokens: 1_000_000, composer: composer) == .worksWell
            }
            #expect(covered, "\(builtIn)")
        }
    }
}
