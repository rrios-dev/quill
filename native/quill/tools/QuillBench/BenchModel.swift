import Foundation
import ModelKit
import RewriteKit

/// `provider:model` as the bench's command line takes it: `apple.on-device:system`,
/// `openrouter:anthropic/claude-sonnet-5.5`.
struct ModelSpec: Hashable, Sendable, CustomStringConvertible, Codable {
    var provider: ProviderID
    var model: ModelID

    init(provider: ProviderID, model: ModelID) {
        self.provider = provider
        self.model = model
    }

    init?(_ text: String) {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let provider = String(text[..<colon])
        let model = String(text[text.index(after: colon)...])
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        self.init(provider: ProviderID(rawValue: provider), model: ModelID(rawValue: model))
    }

    var description: String { "\(provider.rawValue):\(model.rawValue)" }
    var selection: ModelSelection { ModelSelection(provider: provider, model: model) }

    var isOnDevice: Bool { provider == AppleOnDeviceProvider.providerID }

    /// The canonical model identity (ARCHITECTURE §5.1): `vendor/model`; OpenAI's own ids
    /// get `openai/`; the on-device model is `apple/on-device@<macOS major>`.
    var canonicalIdentity: String { ModelIdentity.canonical(selection) }

    /// The vendor, from the canonical identity's `creator/` prefix.
    var vendor: String {
        if isOnDevice { return "apple" }
        return String(canonicalIdentity.prefix { $0 != "/" }).lowercased()
    }
}

/// Where the bench reads and writes (BENCH §2–§3).
struct BenchPaths: Sendable {
    /// `native/quill/tools/QuillBench/data` — committed data.
    var data: URL
    /// `~/Library/Application Support/<bundle id>/bench` — results, sealed failures,
    /// personal cases. Never in the repository.
    var support: URL

    var devCases: URL { data.appendingPathComponent("cases/dev", isDirectory: true) }
    var holdoutCases: URL { data.appendingPathComponent("cases/holdout", isDirectory: true) }
    var holdoutLock: URL { data.appendingPathComponent("cases/holdout.lock") }
    var prices: URL { data.appendingPathComponent("prices.json") }
    var budget: URL { data.appendingPathComponent("budget.json") }
    var baselines: URL { data.appendingPathComponent("baselines", isDirectory: true) }
    var results: URL { support.appendingPathComponent("results", isDirectory: true) }
    var sealed: URL { support.appendingPathComponent("sealed", isDirectory: true) }
    var personalCases: URL { support.appendingPathComponent("cases", isDirectory: true) }
    var ledger: URL { results.appendingPathComponent("ledger.json") }

    static func standard(data: URL) -> BenchPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.rrios.quill/bench", isDirectory: true)
        return BenchPaths(data: data, support: support)
    }
}

/// The dated price table (`prices.json`), used when a model list publishes no price and
/// for dry runs before any key exists.
struct PriceTable: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let inputPerMillion: Double
        let outputPerMillion: Double
    }

    let date: String
    let models: [String: Entry]

    static func load(_ url: URL) throws -> PriceTable {
        try JSONDecoder().decode(PriceTable.self, from: Data(contentsOf: url))
    }

    func pricing(for spec: ModelSpec) -> ModelPricing? {
        if spec.isOnDevice { return ModelPricing(inputPerMillion: 0, outputPerMillion: 0) }
        return models[spec.canonicalIdentity].map {
            ModelPricing(inputPerMillion: $0.inputPerMillion, outputPerMillion: $0.outputPerMillion)
        }
    }
}

/// The owner-approved spending limits (README Q9, set at OS3). Until approved, both are
/// zero and every hosted run is refused unless the command line raises them — which the
/// agent never does beyond what the owner approved.
struct ApprovedBudget: Decodable, Sendable {
    let perRun: Double
    let total: Double
    let approvedAt: String?

    static let none = ApprovedBudget(perRun: 0, total: 0, approvedAt: nil)

    static func load(_ url: URL) -> ApprovedBudget {
        (try? JSONDecoder().decode(ApprovedBudget.self, from: Data(contentsOf: url))) ?? .none
    }
}
