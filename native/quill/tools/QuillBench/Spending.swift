import Foundation
import ModelKit

/// How a hosted call's cost is bounded and charged (BENCH §3).
enum CallCost {
    /// Every hosted call — generation or judge — is capped at max(1,024, 4 × input
    /// tokens): room for a reasoning model's hidden tokens.
    static func outputCap(estimatedInputTokens: Int) -> Int {
        max(1_024, 4 * estimatedInputTokens)
    }

    /// A true upper bound: input counted as one token per character, output at its cap.
    static func upperBound(inputCharacters: Int, outputCap: Int, pricing: ModelPricing) -> Double {
        (Double(inputCharacters) * pricing.inputPerMillion + Double(outputCap) * pricing.outputPerMillion) / 1_000_000
    }

    /// The typical cost a dry run estimates: estimated input tokens, and an answer about
    /// as long as the input.
    static func estimate(estimatedInputTokens: Int, estimatedOutputTokens: Int, pricing: ModelPricing) -> Double {
        (Double(estimatedInputTokens) * pricing.inputPerMillion
            + Double(estimatedOutputTokens) * pricing.outputPerMillion) / 1_000_000
    }

    /// The actual cost from reported usage; a call with no usage is charged its upper bound.
    static func actual(usage: TokenUsage?, upperBound: Double, pricing: ModelPricing) -> Double {
        usage.map { pricing.cost(of: $0) } ?? upperBound
    }

    static func characters(of request: GenerationRequest) -> Int {
        request.instructions.count + request.input.count + request.examples.reduce(0) { $0 + $1.input.count + $1.output.count }
    }
}

/// The spending of one run against its budget: aborts as soon as the next call's upper
/// bound could take it past.
final class SpendMeter: @unchecked Sendable {
    let budget: Double?
    private let lock = NSLock()
    private var spent: Double = 0
    private var requests = 0
    let maxRequests: Int?

    init(budget: Double?, maxRequests: Int?) {
        self.budget = budget
        self.maxRequests = maxRequests
    }

    var total: Double { lock.withLock { spent } }
    var requestCount: Int { lock.withLock { requests } }

    /// Whether a call with this upper bound may start.
    func mayStart(upperBound: Double) -> Bool {
        lock.withLock {
            if let maxRequests, requests >= maxRequests { return false }
            guard let budget else { return true }
            return spent + upperBound <= budget
        }
    }

    func charge(_ amount: Double) {
        lock.withLock {
            spent += amount
            requests += 1
        }
    }
}

/// Every hosted run's actual cost, appended to `results/ledger.json`. `--total-budget`
/// refuses a run whose upper bound would take the ledger past it.
struct Ledger: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var date: Date
        var label: String
        var command: String
        var cost: Double
    }

    var entries: [Entry] = []

    var total: Double { entries.reduce(0) { $0 + $1.cost } }

    static func load(_ url: URL) -> Ledger {
        guard let data = try? Data(contentsOf: url) else { return Ledger() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Ledger.self, from: data)) ?? Ledger()
    }

    func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func append(_ entry: Entry, to url: URL) throws {
        var ledger = load(url)
        ledger.entries.append(entry)
        try ledger.save(url)
    }
}
