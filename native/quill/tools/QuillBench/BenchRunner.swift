import CryptoKit
import Foundation
import ModelKit
import RewriteKit

/// What the runner needs from the outside world — providers, keys, the clock — so tests
/// drive it with scripted transports and no test reaches a real API or sleeps for real.
protocol BenchEnvironment: Sendable {
    func provider(for spec: ModelSpec) -> any ModelProvider
    func hasKey(for provider: ProviderID) -> Bool
    func sleep(for duration: Duration) async
}

/// A case with where it came from.
struct LoadedCase: Sendable {
    var benchCase: BenchCase
    var file: URL
    /// From the owner's own folder, not the committed set: never committable.
    var personal: Bool
}

enum BenchRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case holdoutCase(String)
    case noBudget
    case unpriced(String)
    case estimateOverBudget(estimate: Double, budget: Double)
    case totalBudgetExceeded(upperBound: Double, spent: Double, total: Double)
    case sameVendorJudge(model: String, judge: String)
    case noCases
    case unreadableCases(String)

    var description: String {
        switch self {
        case .holdoutCase(let path): "refused: \(path) is a holdout case file; `run` evaluates development cases only (BENCH §2.2)"
        case .noBudget: "refused: a hosted model or judge needs --budget (BENCH §3)"
        case .unpriced(let model): "refused: no price for \(model); pass --allow-unpriced and --max-requests"
        case .estimateOverBudget(let estimate, let budget): String(format: "refused: estimate $%.4f exceeds --budget $%.4f", estimate, budget)
        case .totalBudgetExceeded(let bound, let spent, let total):
            String(format: "refused: upper bound $%.4f plus $%.4f already spent exceeds --total-budget $%.4f", bound, spent, total)
        case .sameVendorJudge(let model, let judge): "refused: judge \(judge) is from the same vendor as \(model)"
        case .noCases: "refused: no cases for the selected profiles"
        case .unreadableCases(let file): "refused: \(file) does not decode"
        }
    }
}

/// Loads case files, refusing holdout ones whatever the path says: a file under
/// `cases/holdout/`, a file whose SHA-256 is in `holdout.lock` (a copy), or a case with a
/// holdout id (BENCH §2.2).
enum CaseLoader {
    static func load(directories: [URL], paths: BenchPaths, profiles: Set<BuiltInProfile>) throws(BenchRefusal) -> [LoadedCase] {
        let lockedHashes = HoldoutLock.hashes(paths.holdoutLock)
        let holdout = paths.holdoutCases.standardizedFileURL.resolvingSymlinksInPath().path
        let committedDev = paths.devCases.standardizedFileURL.resolvingSymlinksInPath().path
        var result: [LoadedCase] = []
        for directory in directories {
            let resolved = directory.standardizedFileURL.resolvingSymlinksInPath()
            if resolved.path.hasPrefix(holdout) { throw .holdoutCase(directory.path) }
            let files = (try? FileManager.default.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file) else { throw .unreadableCases(file.lastPathComponent) }
                if lockedHashes.contains(HoldoutLock.sha256(data)) { throw .holdoutCase(file.path) }
                guard let cases = try? JSONDecoder().decode([BenchCase].self, from: data) else {
                    throw .unreadableCases(file.lastPathComponent)
                }
                if cases.contains(where: { $0.id.contains("-hold-") }) { throw .holdoutCase(file.path) }
                let personal = !resolved.path.hasPrefix(committedDev)
                result += cases.filter { profiles.contains($0.profile) && !$0.isRetired }
                    .map { LoadedCase(benchCase: $0, file: file, personal: personal) }
            }
        }
        return result
    }
}

/// `cases/holdout.lock` (BENCH §2.3): one `<sha256>  <path>` line per locked file, in
/// `shasum -a 256` format. Created at the end of P1-T7b.
enum HoldoutLock {
    static func hashes(_ url: URL) -> Set<String> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) })
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One evaluated (or voided) run of one case.
struct CaseRun: Codable, Sendable {
    var caseID: String
    var profile: BuiltInProfile
    var model: ModelSpec
    var repeatIndex: Int
    var personal: Bool
    var critical: Bool
    var promptHash: String?
    var state: String
    var output: String?
    var failedChecks: [String]
    var checkDetails: [String: String]
    var hardPass: Bool
    var infrastructureFailure: String?
    var similarity: Double?
    var judge: JudgeScores?
    var judgeFailure: String?
    var latencyMilliseconds: Double?
    var inputTokens: Int?
    var outputTokens: Int?
    var cost: Double
    var strippedPreamble: Bool
    var attempts: Int
}

struct ProfileModelSummary: Codable, Sendable {
    var profile: BuiltInProfile
    var model: ModelSpec
    var runs: Int
    var voided: Int
    var hardPassRate: Double
    var criticalFailures: [String]
    var meanSimilarity: Double?
    var judgeMean: Double?
    var judgeDimensionMeans: [String: Double]?
    var p50LatencyMilliseconds: Double?
    var cost: Double
    var strippedPreambles: Int
    /// "not ready (development NN %)" below 95 %; "development NN %" otherwise.
    var developmentVerdict: String
    /// The prompt hash every counted run used; nil when they differed.
    var promptHash: String?
    /// The canonical identity when the run was made: the on-device one names the macOS
    /// major it was measured on, which the export must not re-derive from the current
    /// system. Nil in reports written before it was recorded.
    var identity: String?
}

struct RunReport: Codable, Sendable {
    var label: String
    var date: Date
    var command: String
    var evaluationVersion: Int
    var promptVersions: [String: Int]
    var judge: ModelSpec?
    var rubricVersion: Int?
    var repeats: Int
    var runs: [CaseRun]
    var summaries: [ProfileModelSummary]
    var estimate: Double
    var upperBound: Double
    var cost: Double
    var aborted: String?
    var dryRun: Bool
}

struct RunOptions: Sendable {
    var profiles: [BuiltInProfile]
    var models: [ModelSpec]
    var repeats = 3
    var judge: ModelSpec?
    var dryRun = false
    var budget: Double?
    var totalBudget: Double?
    var allowUnpriced = false
    var maxRequests: Int?
    var label = "run"
    var caseDirectories: [URL] = []
}

struct BenchRunner: Sendable {
    let paths: BenchPaths
    let environment: any BenchEnvironment
    let engine: GenerationEngine
    let composer: PromptComposer
    let prices: PriceTable
    let rubric: JudgeClient.Rubric?

    /// The development threshold below which a model is "not ready (development NN %)".
    static let developmentPassRate = 0.95
    /// On-device rate limits are retried this many times, with backoff (BENCH intro).
    static let rateLimitRetries = 5

    struct ModelInfo: Sendable {
        var contextTokens: Int?
        var pricing: ModelPricing?
        var runsOnDevice: Bool
    }

    /// Context and price: from the provider's model list when a key exists, else from
    /// `prices.json` and the canonical identity (BENCH §3, before any key exists).
    func info(for spec: ModelSpec) async -> ModelInfo {
        let provider = environment.provider(for: spec)
        if spec.isOnDevice {
            return ModelInfo(contextTokens: provider.descriptor.traits.maxContextTokens,
                             pricing: ModelPricing(inputPerMillion: 0, outputPerMillion: 0), runsOnDevice: true)
        }
        var listed: ModelDescriptor?
        if environment.hasKey(for: spec.provider) {
            listed = try? await provider.models().first { $0.id == spec.model }
        }
        let onDevice: Bool = if case .onDevice = provider.descriptor.traits.execution { true } else { false }
        return ModelInfo(contextTokens: listed?.contextTokens ?? 128_000,
                         pricing: listed?.pricing ?? prices.pricing(for: spec),
                         runsOnDevice: onDevice)
    }

    /// Calls the run would make, with their estimate and upper bound, before any request.
    struct Plan: Sendable {
        var calls = 0
        var estimate = 0.0
        var upperBound = 0.0
        var hosted = false
    }

    func run(_ options: RunOptions, log: @Sendable (String) -> Void = { print($0) }) async throws(BenchRefusal) -> RunReport {
        let directories = options.caseDirectories.isEmpty ? [paths.devCases] : options.caseDirectories
        let cases = try CaseLoader.load(directories: directories, paths: paths, profiles: Set(options.profiles))
        guard !cases.isEmpty else { throw .noCases }

        var infos: [ModelSpec: ModelInfo] = [:]
        for spec in options.models + (options.judge.map { [$0] } ?? []) { infos[spec] = await info(for: spec) }

        if let judge = options.judge {
            for spec in options.models where spec.vendor == judge.vendor {
                throw .sameVendorJudge(model: spec.description, judge: judge.description)
            }
        }

        let plan = try await planFor(options: options, cases: cases, infos: infos)
        if plan.hosted, !options.dryRun {
            guard let budget = options.budget else { throw .noBudget }
            if plan.estimate > budget { throw .estimateOverBudget(estimate: plan.estimate, budget: budget) }
            let ledger = Ledger.load(paths.ledger)
            let total = options.totalBudget ?? ApprovedBudget.load(paths.budget).total
            if ledger.total + plan.upperBound > total {
                throw .totalBudgetExceeded(upperBound: plan.upperBound, spent: ledger.total, total: total)
            }
        }

        var report = RunReport(
            label: options.label, date: Date(), command: "run", evaluationVersion: RewriteKitVersion.evaluation,
            promptVersions: Dictionary(uniqueKeysWithValues: PromptStrategy.allCases.map { ($0.rawValue, composer.version(of: $0)) }),
            judge: options.judge, rubricVersion: options.judge == nil ? nil : rubric?.version, repeats: options.repeats,
            runs: [], summaries: [], estimate: plan.estimate, upperBound: plan.upperBound, cost: 0, aborted: nil,
            dryRun: options.dryRun)
        if options.dryRun {
            log(String(format: "dry run: %d calls, estimate $%.4f, upper bound $%.4f", plan.calls, plan.estimate, plan.upperBound))
            return report
        }

        let meter = SpendMeter(budget: plan.hosted ? options.budget : nil, maxRequests: options.maxRequests)
        let executed = await execute(cases: cases, options: options, infos: infos, meter: meter)
        report.runs = executed.runs
        report.aborted = executed.aborted
        report.cost = meter.total
        report.summaries = Self.summarize(report.runs, profiles: options.profiles, models: options.models)
        if plan.hosted {
            try? Ledger.append(.init(date: report.date, label: options.label, command: "run", cost: report.cost), to: paths.ledger)
        }
        return report
    }

    /// Runs every case × repeat for each profile × model; `run` and `gate` share it.
    func execute(cases: [LoadedCase], options: RunOptions, infos: [ModelSpec: ModelInfo],
                 meter: SpendMeter) async -> (runs: [CaseRun], aborted: String?) {
        let judgeClient: JudgeClient? = options.judge.flatMap { spec in
            rubric.map { JudgeClient(spec: spec, provider: environment.provider(for: spec), rubric: $0, pricing: infos[spec]?.pricing) }
        }
        var runs: [CaseRun] = []
        for profileID in options.profiles {
            let profile = (try? BuiltInProfiles.make(profileID, language: "es")) ?? Profile(
                name: profileID.rawValue, symbol: "", settings: ProfileSettings(scope: .rewrite))
            for spec in options.models {
                let info = infos[spec] ?? ModelInfo(contextTokens: nil, pricing: nil, runsOnDevice: false)
                for loaded in cases where loaded.benchCase.profile == profileID {
                    for repeatIndex in 0..<options.repeats {
                        let outcome = await runCase(loaded, profile: profile, spec: spec, info: info, repeatIndex: repeatIndex,
                                                    judge: judgeClient, meter: meter)
                        switch outcome {
                        case .run(let caseRun): runs.append(caseRun)
                        case .aborted(let reason): return (runs, reason)
                        }
                    }
                }
            }
        }
        return (runs, nil)
    }

    /// The prompt hash a profile would have on a model — what gate verdicts key on.
    func promptHash(_ profileID: BuiltInProfile, contextTokens: Int?) -> String? {
        guard let profile = try? BuiltInProfiles.make(profileID, language: "es") else { return nil }
        return composer.promptHash(profile: profile, strategy: PromptStrategy.forContext(contextTokens))
    }

    func planFor(options: RunOptions, cases: [LoadedCase], infos: [ModelSpec: ModelInfo]) async throws(BenchRefusal) -> Plan {
        var plan = Plan()
        for spec in options.models + (options.judge.map { [$0] } ?? []) where !spec.isOnDevice {
            plan.hosted = true
            if infos[spec]?.pricing == nil, !(options.allowUnpriced && options.maxRequests != nil) {
                throw .unpriced(spec.canonicalIdentity)
            }
        }
        for profileID in options.profiles {
            guard let profile = try? BuiltInProfiles.make(profileID, language: "es") else { continue }
            let profileCases = cases.filter { $0.benchCase.profile == profileID }
            for spec in options.models {
                let info = infos[spec]
                for loaded in profileCases {
                    let prompt = await composer.compose(profile: profile, input: loaded.benchCase.input, model: spec.model,
                                                        contextTokens: info?.contextTokens, pinnedExample: loaded.benchCase.pinnedExample)
                    let inputTokens = TokenEstimate.characters(in: prompt.request)
                    let characters = CallCost.characters(of: prompt.request)
                    let cap = CallCost.outputCap(estimatedInputTokens: inputTokens)
                    let outputTokens = TokenEstimate.characters(in: GenerationRequest(model: spec.model, instructions: "", input: loaded.benchCase.input))
                    let repeats = Double(options.repeats)
                    plan.calls += options.repeats
                    if let pricing = info?.pricing {
                        plan.estimate += repeats * CallCost.estimate(estimatedInputTokens: inputTokens, estimatedOutputTokens: outputTokens, pricing: pricing)
                        plan.upperBound += repeats * CallCost.upperBound(inputCharacters: characters, outputCap: cap, pricing: pricing)
                    }
                    // The judge grades rewrite profiles only.
                    if let judge = options.judge, profile.settings.scope == .rewrite, let rubric {
                        let judgeInfo = infos[judge]
                        let message = JudgeClient.message(input: loaded.benchCase.input, output: loaded.benchCase.input,
                                                          references: loaded.benchCase.references)
                        let request = GenerationRequest(model: judge.model, instructions: rubric.instructions(for: profileID), input: message)
                        let judgeTokens = TokenEstimate.characters(in: request)
                        let judgeCap = CallCost.outputCap(estimatedInputTokens: judgeTokens)
                        plan.calls += options.repeats
                        if let pricing = judgeInfo?.pricing {
                            plan.estimate += repeats * CallCost.estimate(estimatedInputTokens: judgeTokens, estimatedOutputTokens: 120, pricing: pricing)
                            plan.upperBound += repeats * CallCost.upperBound(inputCharacters: CallCost.characters(of: request), outputCap: judgeCap, pricing: pricing)
                        }
                    }
                }
            }
        }
        return plan
    }

    enum CaseOutcome: Sendable {
        case run(CaseRun)
        case aborted(String)
    }

    /// One case, one repeat, with the infrastructure retries of BENCH §3.
    func runCase(_ loaded: LoadedCase, profile: Profile, spec: ModelSpec, info: ModelInfo, repeatIndex: Int,
                 judge: JudgeClient?, meter: SpendMeter) async -> CaseOutcome {
        let benchCase = loaded.benchCase
        let provider = environment.provider(for: spec)
        var cap: Int?
        var attempts = 0
        var rateLimitRetries = 0
        var lengthRetried = false
        var cost = 0.0
        var outcome: GenerationEngine.Outcome

        while true {
            attempts += 1
            var request = GenerationEngine.Request(
                profile: profile, input: benchCase.input, model: spec.selection, contextTokens: info.contextTokens,
                runsOnDevice: info.runsOnDevice, pinnedExample: benchCase.pinnedExample, streams: false)
            request.maxOutputTokens = nil
            var upperBound = 0.0
            if !spec.isOnDevice {
                let prompt = await composer.compose(profile: profile, input: benchCase.input, model: spec.model,
                                                    contextTokens: info.contextTokens, pinnedExample: benchCase.pinnedExample)
                let baseCap = CallCost.outputCap(estimatedInputTokens: TokenEstimate.characters(in: prompt.request))
                cap = cap ?? baseCap
                request.maxOutputTokens = cap
                if let pricing = info.pricing {
                    upperBound = CallCost.upperBound(inputCharacters: CallCost.characters(of: prompt.request), outputCap: cap!, pricing: pricing)
                }
                guard meter.mayStart(upperBound: upperBound) else {
                    return .aborted(String(format: "budget: the next call's upper bound $%.4f would pass $%.4f (spent $%.4f)",
                                           upperBound, meter.budget ?? 0, meter.total))
                }
            }
            outcome = await engine.run(request, provider: provider)
            if !spec.isOnDevice {
                let charged = info.pricing.map { CallCost.actual(usage: outcome.result?.usage, upperBound: upperBound, pricing: $0) } ?? 0
                meter.charge(charged)
                cost += charged
            }

            // Rate limiting: an infrastructure failure, retried with backoff.
            if case .failed(.rateLimited, _) = outcome.state, rateLimitRetries < Self.rateLimitRetries {
                rateLimitRetries += 1
                await environment.sleep(for: .seconds(1 << rateLimitRetries))
                continue
            }
            // A length finish with no visible output spent the cap on hidden reasoning:
            // retried once with double the cap, never a quality failure.
            if case .truncated(let partial) = outcome.state,
               partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let current = cap {
                if !lengthRetried {
                    lengthRetried = true
                    cap = current * 2
                    continue
                }
                return .run(voided(benchCase, loaded: loaded, spec: spec, repeatIndex: repeatIndex,
                                   reason: "length finish with no visible output, twice", attempts: attempts, cost: cost))
            }
            break
        }

        let report = Evaluation.evaluate(benchCase, state: outcome.state, scope: profile.settings.scope)
        var caseRun = CaseRun(
            caseID: benchCase.id, profile: benchCase.profile, model: spec, repeatIndex: repeatIndex,
            personal: loaded.personal, critical: benchCase.critical, promptHash: outcome.prompt?.promptHash,
            state: Self.describe(outcome.state), output: report.output,
            failedChecks: report.failedChecks.map(\.name),
            checkDetails: Dictionary(uniqueKeysWithValues: report.failedChecks.compactMap { check in check.detail.map { (check.name, $0) } }),
            hardPass: report.hardChecksPassed, infrastructureFailure: report.infrastructureFailure,
            similarity: report.referenceSimilarity, judge: nil, judgeFailure: nil,
            latencyMilliseconds: outcome.result.map { Self.milliseconds($0.latency) },
            inputTokens: outcome.result?.usage?.inputTokens, outputTokens: outcome.result?.usage?.outputTokens,
            cost: cost, strippedPreamble: outcome.stripped != nil, attempts: attempts)

        if let judge, profile.settings.scope == .rewrite, report.infrastructureFailure == nil, let output = report.output {
            switch await judge.grade(profile: benchCase.profile, gradedVendor: spec.vendor, input: benchCase.input,
                                     output: output, references: benchCase.references, meter: meter) {
            case .success(let verdict):
                caseRun.judge = verdict.scores
                caseRun.cost += verdict.cost
                // The change expectation of a rewrite profile includes the meaning score.
                let rejudged = Evaluation.evaluate(benchCase, state: outcome.state, scope: profile.settings.scope, judge: verdict.scores)
                caseRun.failedChecks = rejudged.failedChecks.map(\.name)
                caseRun.hardPass = rejudged.hardChecksPassed
            case .failure(.overBudget):
                return .aborted("budget: the judge call's upper bound would pass the budget")
            case .failure(let failure):
                caseRun.judgeFailure = "\(failure)"
            }
        }
        return .run(caseRun)
    }

    private func voided(_ benchCase: BenchCase, loaded: LoadedCase, spec: ModelSpec, repeatIndex: Int,
                        reason: String, attempts: Int, cost: Double) -> CaseRun {
        CaseRun(caseID: benchCase.id, profile: benchCase.profile, model: spec, repeatIndex: repeatIndex,
                personal: loaded.personal, critical: benchCase.critical, promptHash: nil, state: "voided",
                output: nil, failedChecks: [], checkDetails: [:], hardPass: false, infrastructureFailure: reason,
                similarity: nil, judge: nil, judgeFailure: nil, latencyMilliseconds: nil, inputTokens: nil,
                outputTokens: nil, cost: cost, strippedPreamble: false, attempts: attempts)
    }

    static func summarize(_ runs: [CaseRun], profiles: [BuiltInProfile], models: [ModelSpec]) -> [ProfileModelSummary] {
        var summaries: [ProfileModelSummary] = []
        for profile in profiles {
            for model in models {
                let all = runs.filter { $0.profile == profile && $0.model == model }
                guard !all.isEmpty else { continue }
                let counted = all.filter { $0.infrastructureFailure == nil }
                let passed = counted.filter(\.hardPass).count
                let rate = counted.isEmpty ? 0 : Double(passed) / Double(counted.count)
                let critical = Set(counted.filter { $0.critical && !$0.hardPass }.map(\.caseID)).sorted()
                let similarities = counted.compactMap(\.similarity)
                let judged = counted.compactMap(\.judge)
                let latencies = counted.compactMap(\.latencyMilliseconds).sorted()
                let percent = Int((rate * 100).rounded(.down))
                summaries.append(ProfileModelSummary(
                    profile: profile, model: model, runs: counted.count, voided: all.count - counted.count,
                    hardPassRate: rate, criticalFailures: critical,
                    meanSimilarity: similarities.isEmpty ? nil : similarities.reduce(0, +) / Double(similarities.count),
                    judgeMean: judged.isEmpty ? nil : judged.map(\.mean).reduce(0, +) / Double(judged.count),
                    judgeDimensionMeans: judged.isEmpty ? nil : [
                        "meaning": judged.map(\.meaning).reduce(0, +) / Double(judged.count),
                        "profileMatch": judged.map(\.profileMatch).reduce(0, +) / Double(judged.count),
                        "nothingAdded": judged.map(\.nothingAdded).reduce(0, +) / Double(judged.count),
                        "fluency": judged.map(\.fluency).reduce(0, +) / Double(judged.count),
                    ],
                    p50LatencyMilliseconds: latencies.isEmpty ? nil : latencies[latencies.count / 2],
                    cost: all.reduce(0) { $0 + $1.cost },
                    strippedPreambles: counted.filter(\.strippedPreamble).count,
                    developmentVerdict: rate < developmentPassRate ? "not ready (development \(percent) %)" : "development \(percent) %",
                    promptHash: Set(counted.compactMap(\.promptHash)).count == 1 ? counted.first?.promptHash : nil,
                    identity: model.canonicalIdentity))
            }
        }
        return summaries
    }

    static func describe(_ state: GenerationState) -> String {
        switch state {
        case .idle: "idle"
        case .generating: "generating"
        case .ready(_, let flags): flags.isEmpty ? "ready" : "flagged"
        case .noChanges: "noChanges"
        case .truncated: "truncated"
        case .refused: "refused"
        case .tooLong: "tooLong"
        case .failed(let code, _): "failed(\(code))"
        case .cancelled: "cancelled"
        }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
