import Foundation
import ModelKit

/// The canonical model identity readiness is keyed by (ARCHITECTURE §5.1): `vendor/model`;
/// OpenAI's own ids get `openai/`; the on-device model is `apple/on-device@<macOS major>`,
/// because the model changes with major OS releases and the bench re-measures it.
public enum ModelIdentity {
    public static func canonical(
        _ selection: ModelSelection,
        osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> String {
        switch selection.provider.rawValue {
        case "apple.on-device": return "apple/on-device@\(osMajor)"
        case "openai":
            let model = selection.model.rawValue
            return model.contains("/") ? model : "openai/\(model)"
        default: return selection.model.rawValue
        }
    }
}

/// The readiness label a profile × model shows (ARCHITECTURE §5.1), from `readiness.json`.
public enum ReadinessLabel: String, Equatable, Sendable {
    case worksWell = "works well"
    case mayNeedReview = "may need review"
    case notRecommended = "not recommended"
    case notEvaluated = "not evaluated"
    /// A built-in the user edited: a new prompt hash nobody has measured.
    case notEvaluatedEdited = "not evaluated (edited)"
}

/// `readiness.json`, as the bench exports it.
public struct ReadinessIndex: Sendable {
    struct File: Decodable {
        struct Entry: Decodable {
            var promptHash: String
            var model: String
            var evaluationVersion: Int
            var label: String
        }
        var schemaVersion: Int
        var entries: [Entry]
    }

    private let labels: [String: ReadinessLabel]

    public init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        var labels: [String: ReadinessLabel] = [:]
        for entry in file.entries {
            labels[Self.key(entry.promptHash, entry.model, entry.evaluationVersion)] = ReadinessLabel(rawValue: entry.label) ?? .notEvaluated
        }
        self.labels = labels
    }

    /// No measurements: every label is "not evaluated".
    public static let empty = ReadinessIndex(labels: [:])
    private init(labels: [String: ReadinessLabel]) { self.labels = labels }

    static func key(_ hash: String, _ model: String, _ version: Int) -> String { "\(hash)|\(model)|\(version)" }

    /// The label for a prompt hash and a model, measured with the current guards: a
    /// verdict from older guards is not reused.
    public func label(promptHash: String, model: ModelSelection,
                      evaluationVersion: Int = RewriteKitVersion.evaluation, osMajor: Int? = nil) -> ReadinessLabel {
        let identity = osMajor.map { ModelIdentity.canonical(model, osMajor: $0) } ?? ModelIdentity.canonical(model)
        return labels[Self.key(promptHash, identity, evaluationVersion)] ?? .notEvaluated
    }

    /// The label for a profile on a model whose context is `contextTokens`: a built-in the
    /// user edited is "not evaluated (edited)" — its hash differs from the shipped one's.
    public func label(for profile: Profile, model: ModelSelection, contextTokens: Int?,
                      composer: PromptComposer, osMajor: Int? = nil) -> ReadinessLabel {
        var hashes = ProfileHashes(profile: profile, composer: composer)
        return label(model: model, contextTokens: contextTokens, hashes: &hashes, osMajor: osMajor)
    }

    /// The labels of one profile on many models — a provider's whole list. The prompt
    /// hashes and the edited check depend only on the strategy, so they are computed once
    /// per strategy instead of once per model: a list of hundreds is a dictionary look-up
    /// each.
    public func labels(for profile: Profile, models: [(selection: ModelSelection, contextTokens: Int?)],
                       composer: PromptComposer, osMajor: Int? = nil) -> [ModelSelection: ReadinessLabel] {
        var hashes = ProfileHashes(profile: profile, composer: composer)
        var result: [ModelSelection: ReadinessLabel] = [:]
        for model in models {
            result[model.selection] = label(model: model.selection, contextTokens: model.contextTokens, hashes: &hashes, osMajor: osMajor)
        }
        return result
    }

    private func label(model: ModelSelection, contextTokens: Int?, hashes: inout ProfileHashes, osMajor: Int?) -> ReadinessLabel {
        let strategy = PromptStrategy.forContext(contextTokens)
        let found = label(promptHash: hashes.hash(strategy), model: model, osMajor: osMajor)
        if found != .notEvaluated { return found }
        return hashes.isEditedBuiltIn(strategy) ? .notEvaluatedEdited : .notEvaluated
    }

    /// A profile's prompt hash per strategy, and whether it differs from the shipped
    /// built-in's in both languages — each computed the first time it is asked for.
    private struct ProfileHashes {
        let profile: Profile
        let composer: PromptComposer
        private var hashes: [PromptStrategy: String] = [:]
        private var edited: [PromptStrategy: Bool] = [:]

        init(profile: Profile, composer: PromptComposer) {
            self.profile = profile
            self.composer = composer
        }

        mutating func hash(_ strategy: PromptStrategy) -> String {
            if let hash = hashes[strategy] { return hash }
            let hash = composer.promptHash(profile: profile, strategy: strategy)
            hashes[strategy] = hash
            return hash
        }

        mutating func isEditedBuiltIn(_ strategy: PromptStrategy) -> Bool {
            if let known = edited[strategy] { return known }
            let hash = hash(strategy)
            var result = false
            if let builtIn = profile.builtIn, let shipped = try? BuiltInProfiles.make(builtIn, language: "es") {
                let english = (try? BuiltInProfiles.make(builtIn, language: "en")) ?? shipped
                result = composer.promptHash(profile: shipped, strategy: strategy) != hash
                    && composer.promptHash(profile: english, strategy: strategy) != hash
            }
            edited[strategy] = result
            return result
        }
    }
}
