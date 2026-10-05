import CryptoKit
import Foundation
import ModelKit
import RewriteKit

/// `gate-v<n>.json` (BENCH §1.1): thresholds, repeats, judges, rubric and run limits.
struct GateFile: Decodable, Sendable {
    struct SpellingThresholds: Decodable, Sendable {
        let hardPassRate: Double
        let criticalPassEveryRepeat: Bool
        let meanReferenceSimilarity: Double
        let judgeRequired: Bool
    }

    struct RewriteThresholds: Decodable, Sendable {
        let hardPassRate: Double
        let criticalPassEveryRepeat: Bool
        let judgeRequired: Bool
        let judgeMean: Double
        let judgeDimensionMinimum: Double
        let criticalMeaningAtMost: Double
    }

    struct Thresholds: Decodable, Sendable {
        let spellingOnly: SpellingThresholds
        let rewrite: RewriteThresholds
    }

    struct Rubric: Decodable, Sendable {
        let version: Int
        let file: String
        let sha256: String
    }

    let gateVersion: Int
    let minimumRepeats: Int
    let thresholds: Thresholds
    let developmentPassRateToGate: Double
    let confirmationRuns: Int
    let maximumCountedRuns: Int
    let releaseRuns: Int
    let allowedJudges: [String]
    let rubric: Rubric

    static func load(_ url: URL) throws -> GateFile {
        try JSONDecoder().decode(GateFile.self, from: Data(contentsOf: url))
    }
}

/// The verdict logic of BENCH §1.1, pure so it can be tested on fixture runs.
enum GateVerdict {
    enum Outcome: Equatable, Sendable {
        case pass
        case fail([String])
        /// No verdict: the run does not count (an infrastructure failure, no judge).
        case void(String)
    }

    struct Metrics: Codable, Equatable, Sendable {
        var runs: Int
        var hardPassRate: Double
        var criticalAllPassed: Bool
        var meanSimilarity: Double?
        var judgeMean: Double?
        var judgeDimensionMeans: [String: Double]?
    }

    static func compute(_ runs: [CaseRun], scope: ProfileSettings.Scope, gate: GateFile) -> (Outcome, Metrics?) {
        guard !runs.isEmpty else { return (.void("no runs"), nil) }
        if let failure = runs.first(where: { $0.infrastructureFailure != nil })?.infrastructureFailure {
            return (.void("infrastructure: \(failure)"), nil)
        }
        if scope == .rewrite, let failure = runs.first(where: { $0.judgeFailure != nil })?.judgeFailure {
            return (.void("judge: \(failure)"), nil)
        }
        let passed = runs.filter(\.hardPass).count
        let rate = Double(passed) / Double(runs.count)
        let criticalAll = runs.filter(\.critical).allSatisfy(\.hardPass)
        let similarities = runs.compactMap(\.similarity)
        let meanSimilarity = similarities.isEmpty ? nil : similarities.reduce(0, +) / Double(similarities.count)
        let judged = runs.compactMap(\.judge)
        var metrics = Metrics(runs: runs.count, hardPassRate: rate, criticalAllPassed: criticalAll,
                              meanSimilarity: meanSimilarity, judgeMean: nil, judgeDimensionMeans: nil)
        if !judged.isEmpty {
            func mean(_ key: KeyPath<JudgeScores, Double>) -> Double { judged.map { $0[keyPath: key] }.reduce(0, +) / Double(judged.count) }
            metrics.judgeMean = judged.map(\.mean).reduce(0, +) / Double(judged.count)
            metrics.judgeDimensionMeans = ["meaning": mean(\.meaning), "profileMatch": mean(\.profileMatch),
                                           "nothingAdded": mean(\.nothingAdded), "fluency": mean(\.fluency)]
        }

        var reasons: [String] = []
        switch scope {
        case .spellingOnly:
            let t = gate.thresholds.spellingOnly
            if rate < t.hardPassRate { reasons.append(String(format: "hard checks %.0f %%", rate * 100)) }
            if t.criticalPassEveryRepeat, !criticalAll { reasons.append("a critical case failed a repeat") }
            if (meanSimilarity ?? 0) < t.meanReferenceSimilarity {
                reasons.append(String(format: "similarity %.2f", meanSimilarity ?? 0))
            }
        case .rewrite:
            let t = gate.thresholds.rewrite
            guard judged.count == runs.count else { return (.void("not evaluated: a rewrite profile needs a judge"), metrics) }
            if rate < t.hardPassRate { reasons.append(String(format: "hard checks %.0f %%", rate * 100)) }
            if t.criticalPassEveryRepeat, !criticalAll { reasons.append("a critical case failed a repeat") }
            if (metrics.judgeMean ?? 0) < t.judgeMean { reasons.append(String(format: "judge mean %.2f", metrics.judgeMean ?? 0)) }
            for (dimension, value) in (metrics.judgeDimensionMeans ?? [:]).sorted(by: { $0.key < $1.key })
            where value < t.judgeDimensionMinimum {
                reasons.append(String(format: "%@ %.2f", dimension, value))
            }
            if runs.contains(where: { $0.critical && ($0.judge?.meaning ?? 5) <= t.criticalMeaningAtMost }) {
                reasons.append("a critical case's meaning scored ≤ \(Int(t.criticalMeaningAtMost))")
            }
        }
        return (reasons.isEmpty ? .pass : .fail(reasons), metrics)
    }
}

/// `baselines/gate-log.json`: every gate evaluation, so how often the holdout was looked
/// at is on record (BENCH §2.2). Committed; holds verdicts only.
struct GateLog: Codable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var date: Date
        var label: String
        var profile: BuiltInProfile
        var model: String
        var identity: String
        var promptHash: String
        var gateVersion: Int
        var evaluationVersion: Int
        var lockHash: String
        var judge: String?
        /// Counted against the gate file's maximum; infrastructure failures are not.
        var counted: Bool
        var release: Bool
        /// "ready (confirmed)", "ready (unconfirmed)", "not ready", "void: …".
        var verdict: String
        var reasons: [String]
        var metrics: GateVerdict.Metrics?
    }

    var entries: [Entry] = []

    static func load(_ url: URL) -> GateLog {
        guard let data = try? Data(contentsOf: url) else { return GateLog() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(GateLog.self, from: data)) ?? GateLog()
    }

    func save(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Runs already counted for a profile × model under this gate file, evaluation version
    /// and lock — across prompt hashes, so every look at the holdout spends from one budget.
    func countedRuns(profile: BuiltInProfile, identity: String, gateVersion: Int, evaluationVersion: Int,
                     lockHash: String, release: Bool) -> Int {
        entries.filter {
            $0.profile == profile && $0.identity == identity && $0.gateVersion == gateVersion
                && $0.evaluationVersion == evaluationVersion && $0.lockHash == lockHash
                && $0.counted && $0.release == release
        }.count
    }

    /// The previous counted entry for the same profile × model and evaluation version.
    func lastCounted(profile: BuiltInProfile, identity: String, evaluationVersion: Int) -> Entry? {
        entries.last { $0.profile == profile && $0.identity == identity && $0.evaluationVersion == evaluationVersion && $0.counted }
    }
}

enum GateRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    case tooFewRepeats(Int, minimum: Int)
    case judgeNotAllowed(String)
    case judgeRequired(BuiltInProfile)
    case sameVendorJudge(model: String, judge: String)
    case rubricChanged
    case noDevelopmentPass(profile: BuiltInProfile, model: String, hash: String)
    case countedRunsExhausted(profile: BuiltInProfile, model: String)
    case releaseRunsExhausted(profile: BuiltInProfile, model: String)
    case noHoldout(BuiltInProfile)
    case lockMismatch([String])
    case bench(BenchRefusal)

    var description: String {
        switch self {
        case .tooFewRepeats(let repeats, let minimum): "refused: \(repeats) repeats; the gate needs at least \(minimum)"
        case .judgeNotAllowed(let judge): "refused: \(judge) is not an allowed judge in the gate file"
        case .judgeRequired(let profile): "refused: \(profile.rawValue) is a rewrite profile; the gate needs --judge"
        case .sameVendorJudge(let model, let judge): "refused: judge \(judge) is from the same vendor as \(model)"
        case .rubricChanged: "refused: the rubric no longer matches the gate file's hash"
        case .noDevelopmentPass(let profile, let model, let hash):
            "refused: no development run of \(profile.rawValue) on \(model) with prompt \(hash.prefix(12)) reached 95 %"
        case .countedRunsExhausted(let profile, let model): "refused: \(profile.rawValue) on \(model) has used its counted gate runs"
        case .releaseRunsExhausted(let profile, let model): "refused: \(profile.rawValue) on \(model) has used its release runs"
        case .noHoldout(let profile): "refused: no holdout cases for \(profile.rawValue)"
        case .lockMismatch(let files): "refused: holdout.lock does not match \(files.joined(separator: ", "))"
        case .bench(let refusal): refusal.description
        }
    }
}

struct GateOptions: Sendable {
    var profiles: [BuiltInProfile]
    var models: [ModelSpec]
    var repeats: Int?
    var judge: ModelSpec?
    var budget: Double?
    var totalBudget: Double?
    var label = "gate"
    var release = false
    var gateFile = "gate-v1.json"
}

/// One gate run's committed record: verdicts only.
struct GateReport: Codable, Sendable {
    var label: String
    var date: Date
    var command = "gate"
    var entries: [GateLog.Entry]
    var cost: Double
}

extension BenchRunner {
    var gateLogURL: URL { paths.baselines.appendingPathComponent("gate-log.json") }

    func lockHash() -> String {
        (try? Data(contentsOf: paths.holdoutLock)).map(HoldoutLock.sha256) ?? "unlocked"
    }

    /// Whether a development run of this profile × model and prompt hash reached the
    /// gate file's development threshold — the holdout is not a tuning signal.
    func developmentPassed(_ profile: BuiltInProfile, _ spec: ModelSpec, hash: String, threshold: Double) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.results, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files where file.pathExtension == "json" && file.lastPathComponent != "ledger.json" {
            guard let report = try? decoder.decode(RunReport.self, from: Data(contentsOf: file)),
                  report.command == "run", report.evaluationVersion == RewriteKitVersion.evaluation else { continue }
            if report.summaries.contains(where: {
                $0.profile == profile && $0.model == spec && $0.promptHash == hash && $0.hardPassRate >= threshold
            }) { return true }
        }
        return false
    }

    /// `gate` (BENCH §1.1, §2.2): the holdout, under the gate file's rules. Prints only
    /// the verdict table; per-case failures go to the sealed folder outside the repository.
    func gate(_ options: GateOptions, log: @Sendable (String) -> Void = { print($0) }) async throws(GateRefusal) -> GateReport {
        let gateURL = paths.data.appendingPathComponent(options.gateFile)
        guard let gate = try? GateFile.load(gateURL) else { throw .bench(.unreadableCases(options.gateFile)) }
        let repeats = options.repeats ?? gate.minimumRepeats
        guard repeats >= gate.minimumRepeats else { throw .tooFewRepeats(repeats, minimum: gate.minimumRepeats) }
        let rubricData = (try? Data(contentsOf: paths.data.appendingPathComponent(gate.rubric.file))) ?? Data()
        guard HoldoutLock.sha256(rubricData) == gate.rubric.sha256 else { throw .rubricChanged }
        if let judge = options.judge {
            guard gate.allowedJudges.contains(judge.description) else { throw .judgeNotAllowed(judge.description) }
            for spec in options.models where spec.vendor == judge.vendor {
                throw .sameVendorJudge(model: spec.description, judge: judge.description)
            }
        }

        // References re-checked when the evaluation version changed; failing ones parked.
        let parked = HoldoutTools(paths: paths).ensureReferencesChecked()

        var infos: [ModelSpec: ModelInfo] = [:]
        for spec in options.models + (options.judge.map { [$0] } ?? []) { infos[spec] = await info(for: spec) }

        let log0 = GateLog.load(gateLogURL)
        let lock = lockHash()
        var plans: [(BuiltInProfile, ModelSpec, String)] = []
        for profileID in options.profiles {
            let scope = (try? BuiltInProfiles.make(profileID, language: "es"))?.settings.scope ?? .rewrite
            if scope == .rewrite, options.judge == nil { throw .judgeRequired(profileID) }
            for spec in options.models {
                guard let hash = promptHash(profileID, contextTokens: infos[spec]?.contextTokens) else { continue }
                guard developmentPassed(profileID, spec, hash: hash, threshold: gate.developmentPassRateToGate) else {
                    throw .noDevelopmentPass(profile: profileID, model: spec.description, hash: hash)
                }
                let used = log0.countedRuns(profile: profileID, identity: spec.canonicalIdentity, gateVersion: gate.gateVersion,
                                            evaluationVersion: RewriteKitVersion.evaluation, lockHash: lock, release: options.release)
                if options.release, used >= gate.releaseRuns { throw .releaseRunsExhausted(profile: profileID, model: spec.description) }
                if !options.release, used >= gate.maximumCountedRuns { throw .countedRunsExhausted(profile: profileID, model: spec.description) }
                plans.append((profileID, spec, hash))
            }
        }

        let holdout = loadHoldout(profiles: Set(options.profiles), excluding: parked)
        for profileID in options.profiles where !holdout.contains(where: { $0.benchCase.profile == profileID }) {
            throw .noHoldout(profileID)
        }
        // The holdout must be what the lock says.
        if FileManager.default.fileExists(atPath: paths.holdoutLock.path) {
            let mismatches = HoldoutTools(paths: paths).lockMismatches()
            if !mismatches.isEmpty { throw .lockMismatch(mismatches) }
        }

        // Budget rules are the run's: the same plan, refusals and meter.
        var runOptions = RunOptions(profiles: options.profiles, models: options.models, repeats: repeats)
        runOptions.judge = options.judge
        runOptions.budget = options.budget
        runOptions.totalBudget = options.totalBudget
        runOptions.label = options.label
        let plan: Plan
        do { plan = try await makeGatePlan(runOptions, cases: holdout, infos: infos) } catch { throw .bench(error) }
        if plan.hosted {
            guard let budget = options.budget else { throw .bench(.noBudget) }
            if plan.estimate > budget { throw .bench(.estimateOverBudget(estimate: plan.estimate, budget: budget)) }
            let total = options.totalBudget ?? ApprovedBudget.load(paths.budget).total
            let ledger = Ledger.load(paths.ledger)
            if ledger.total + plan.upperBound > total {
                throw .bench(.totalBudgetExceeded(upperBound: plan.upperBound, spent: ledger.total, total: total))
            }
        }
        let meter = SpendMeter(budget: plan.hosted ? options.budget : nil, maxRequests: nil)
        let executed = await execute(cases: holdout, options: runOptions, infos: infos, meter: meter)

        var gateLog = log0
        var entries: [GateLog.Entry] = []
        var sealed: [CaseRun] = []
        for (profileID, spec, hash) in plans {
            let runs = executed.runs.filter { $0.profile == profileID && $0.model == spec }
            let scope = (try? BuiltInProfiles.make(profileID, language: "es"))?.settings.scope ?? .rewrite
            var (outcome, metrics) = GateVerdict.compute(runs, scope: scope, gate: gate)
            if let aborted = executed.aborted { outcome = .void("aborted: \(aborted)") }
            if let gap = holdoutCoverageGap(profileID, in: holdout) {
                outcome = .void("not evaluated (parked cases leave no \(gap.rawValue) case)")
            }
            if case .void(let reason) = outcome, reason.contains("rateLimited"), spec.isOnDevice {
                outcome = .void("not evaluated (CLI rate-limited)")
            }
            let previous = gateLog.lastCounted(profile: profileID, identity: spec.canonicalIdentity,
                                               evaluationVersion: RewriteKitVersion.evaluation)
            let verdict: String
            var reasons: [String] = []
            switch outcome {
            case .pass:
                let confirmed = previous?.promptHash == hash && previous?.verdict.hasPrefix("ready") == true
                verdict = confirmed ? "ready (confirmed)" : "ready (unconfirmed)"
            case .fail(let why):
                verdict = "not ready"
                reasons = why
            case .void(let why):
                verdict = "void"
                reasons = [why]
            }
            let counted: Bool = if case .void = outcome { false } else { true }
            let entry = GateLog.Entry(
                date: Date(), label: options.label, profile: profileID, model: spec.description, identity: spec.canonicalIdentity,
                promptHash: hash, gateVersion: gate.gateVersion, evaluationVersion: RewriteKitVersion.evaluation,
                lockHash: lock, judge: options.judge?.description, counted: counted, release: options.release,
                verdict: verdict, reasons: reasons, metrics: metrics)
            gateLog.entries.append(entry)
            entries.append(entry)
            sealed += runs.filter { !$0.hardPass || $0.infrastructureFailure != nil }
        }
        try? gateLog.save(gateLogURL)
        try? HoldoutTools(paths: paths).writeSealed(sealed, label: options.label)
        if plan.hosted {
            try? Ledger.append(.init(date: Date(), label: options.label, command: "gate", cost: meter.total), to: paths.ledger)
        }

        let used = gateLog.entries.filter(\.counted)
        log("| profile | model | runs | hard | critical | sim | judge | counted run | verdict |\n|---|---|---|---|---|---|---|---|---|")
        for entry in entries {
            let count = used.filter { $0.profile == entry.profile && $0.identity == entry.identity && $0.lockHash == lock
                && $0.gateVersion == entry.gateVersion && $0.release == entry.release }.count
            let metrics = entry.metrics
            log("| \(entry.profile.rawValue) | \(entry.model) | \(metrics?.runs ?? 0) | "
                + (metrics.map { "\(Int(($0.hardPassRate * 100).rounded(.down))) %" } ?? "–") + " | "
                + (metrics.map { $0.criticalAllPassed ? "pass" : "fail" } ?? "–") + " | "
                + (metrics?.meanSimilarity.map { String(format: "%.2f", $0) } ?? "–") + " | "
                + (metrics?.judgeMean.map { String(format: "%.1f", $0) } ?? "–")
                + " | \(count) of \(entry.release ? gate.releaseRuns : gate.maximumCountedRuns) | \(entry.verdict) |")
        }
        return GateReport(label: options.label, date: Date(), entries: entries, cost: meter.total)
    }

    func loadHoldout(profiles: Set<BuiltInProfile>, excluding parked: Set<String>) -> [LoadedCase] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.holdoutCases, includingPropertiesForKeys: nil)) ?? []
        var result: [LoadedCase] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            guard let cases = try? JSONDecoder().decode([BenchCase].self, from: Data(contentsOf: file)) else { continue }
            result += cases.filter { profiles.contains($0.profile) && !$0.isRetired && !parked.contains($0.id) }
                .map { LoadedCase(benchCase: $0, file: file, personal: false) }
        }
        return result
    }

    private func makeGatePlan(_ options: RunOptions, cases: [LoadedCase], infos: [ModelSpec: ModelInfo]) async throws(BenchRefusal) -> Plan {
        try await planFor(options: options, cases: cases, infos: infos)
    }

    /// While parked cases leave a critical category, exampleBait or refusalBait without a
    /// holdout case, the profile gets no verdict (BENCH §2).
    func holdoutCoverageGap(_ profile: BuiltInProfile, in cases: [LoadedCase]) -> BenchCategory? {
        let required = BenchCategory.allCases.filter(\.isCritical) + [.exampleBait, .refusalBait]
        let present = Set(cases.filter { $0.benchCase.profile == profile }.flatMap(\.benchCase.categories))
        return required.first { !present.contains($0) }
    }
}
