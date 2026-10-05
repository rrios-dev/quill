import Foundation
import ModelKit
import Testing

@testable import QuillBench
@testable import RewriteKit

/// `gate`, verdicts and readiness (PLAN P1-T7b), on fixture cases written here — never the
/// real holdout.
@Suite("Bench gate, verdicts and readiness")
struct GateTests {
    static let realData = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/QuillBench/data", isDirectory: true)

    static let device = ModelSpec(provider: "apple.on-device", model: "system")

    /// Fixture cases for the spelling profile: English, so no Spanish enters Swift.
    static func fixture(_ id: String, input: String, reference: String, categories: [BenchCategory]) -> BenchCase {
        BenchCase(id: id, profile: .spelling, language: "en", categories: categories,
                  critical: categories.contains(where: \.isCritical), input: input, expectChange: true,
                  references: [reference], mustKeep: [])
    }

    static let pairs: [(String, String)] = [
        ("i am runing late today becuase of the trafic", "I am running late today because of the traffic."),
        ("the meting with the client is moved to thursday aftenoon", "The meeting with the client is moved to Thursday afternoon."),
        ("pleese send me the final version of the slides tonite", "Please send me the final version of the slides tonight."),
    ]

    static var holdoutCases: [BenchCase] {
        [
            fixture("spelling-hold-001", input: pairs[0].0, reference: pairs[0].1, categories: [.english, .alreadyCorrect, .whoDidWhat]),
            fixture("spelling-hold-002", input: pairs[1].0, reference: pairs[1].1, categories: [.english, .injection, .noAddedFormulas]),
            fixture("spelling-hold-003", input: pairs[2].0, reference: pairs[2].1, categories: [.english, .exampleBait, .refusalBait]),
        ]
    }

    static var devCases: [BenchCase] {
        pairs.enumerated().map { index, pair in
            fixture("spelling-dev-00\(index + 1)", input: pair.0, reference: pair.1, categories: [.english])
        }
    }

    /// A provider that rewrites every fixture input into its reference — or, for the inputs
    /// in `wrong`, into something that fails.
    static func provider(wrong: Set<String> = [], rateLimited: Bool = false) -> FakeBenchProvider {
        let table = Dictionary(uniqueKeysWithValues: pairs)
        return FakeBenchProvider(id: "apple.on-device", onDevice: true) { request, _ in
            if rateLimited { return .error(.rateLimited(retryAfter: nil)) }
            if wrong.contains(request.input) { return .text("Hello, " + request.input + " Best regards.", .stop, nil) }
            return .text(table[request.input] ?? request.input, .stop, nil)
        }
    }

    struct Sandbox {
        let paths: BenchPaths

        init(holdout: [BenchCase] = GateTests.holdoutCases) throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)", isDirectory: true)
            let data = root.appendingPathComponent("data", isDirectory: true)
            paths = BenchPaths(data: data, support: root.appendingPathComponent("support", isDirectory: true))
            let fm = FileManager.default
            try fm.createDirectory(at: paths.devCases, withIntermediateDirectories: true)
            try fm.createDirectory(at: paths.holdoutCases, withIntermediateDirectories: true)
            try fm.createDirectory(at: data.appendingPathComponent("judge", isDirectory: true), withIntermediateDirectories: true)
            for file in ["gate-v1.json", "judge/rubric-v1.md", "prices.json"] {
                try fm.copyItem(at: GateTests.realData.appendingPathComponent(file), to: data.appendingPathComponent(file))
            }
            try JSONEncoder().encode(GateTests.devCases).write(to: paths.devCases.appendingPathComponent("spelling.json"))
            try JSONEncoder().encode(holdout).write(to: paths.holdoutCases.appendingPathComponent("spelling.json"))
        }

        func runner(_ provider: FakeBenchProvider) throws -> BenchRunner {
            let rubric = try String(contentsOf: paths.data.appendingPathComponent("judge/rubric-v1.md"), encoding: .utf8)
            return BenchRunner(paths: paths, environment: FakeEnvironment([provider]), engine: try GenerationEngine(),
                               composer: try PromptComposer(), prices: try PriceTable.load(paths.prices),
                               rubric: JudgeClient.Rubric(text: rubric, version: 1))
        }

        /// A development run of the spelling profile on the device, saved where `gate` looks.
        func passDevelopment(_ runner: BenchRunner) async throws {
            let report = try await runner.run(RunOptions(profiles: [.spelling], models: [GateTests.device], repeats: 1))
            #expect(report.summaries.first?.hardPassRate == 1)
            _ = try QuillBenchCLI.save(report, paths: paths)
        }
    }

    private func gate(_ runner: BenchRunner, repeats: Int? = nil, judge: ModelSpec? = nil, release: Bool = false,
                      label: String = "gate") async throws -> GateReport {
        var options = GateOptions(profiles: [.spelling], models: [Self.device])
        options.repeats = repeats
        options.judge = judge
        options.release = release
        options.label = label
        return try await runner.gate(options, log: { _ in })
    }

    private func expectRefusal(_ expected: (GateRefusal) -> Bool, _ body: () async throws -> GateReport) async {
        do {
            _ = try await body()
            Issue.record("expected a refusal")
        } catch let refusal as GateRefusal {
            #expect(expected(refusal), "\(refusal)")
        } catch {
            Issue.record("\(error)")
        }
    }

    // MARK: Refusals

    @Test("gate refuses fewer repeats than the gate file's minimum")
    func tooFewRepeats() async throws {
        let sandbox = try Sandbox()
        let runner = try sandbox.runner(Self.provider())
        try await sandbox.passDevelopment(runner)
        await expectRefusal({ if case .tooFewRepeats(2, 3) = $0 { true } else { false } }) { try await gate(runner, repeats: 2) }
    }

    @Test("gate refuses a judge not in the gate file, and a same-vendor judge")
    func judges() async throws {
        let sandbox = try Sandbox()
        let runner = try sandbox.runner(Self.provider())
        await expectRefusal({ if case .judgeNotAllowed = $0 { true } else { false } }) {
            try await gate(runner, judge: ModelSpec(provider: "openrouter", model: "someone/unknown-judge"))
        }
        var options = GateOptions(profiles: [.spelling], models: [ModelSpec(provider: "openrouter", model: "anthropic/claude-other")])
        options.judge = ModelSpec("openrouter:anthropic/claude-sonnet-5.5")
        await expectRefusal({ if case .sameVendorJudge = $0 { true } else { false } }) { try await runner.gate(options, log: { _ in }) }
    }

    @Test("gate refuses a changed rubric")
    func changedRubric() async throws {
        let sandbox = try Sandbox()
        let rubric = sandbox.paths.data.appendingPathComponent("judge/rubric-v1.md")
        try (String(contentsOf: rubric, encoding: .utf8) + "\nOne more rule.\n").write(to: rubric, atomically: true, encoding: .utf8)
        let runner = try sandbox.runner(Self.provider())
        await expectRefusal({ $0 == .rubricChanged }) { try await gate(runner) }
    }

    @Test("gate refuses a prompt hash without a ≥ 95 % development run")
    func needsDevelopmentPass() async throws {
        let sandbox = try Sandbox()
        let runner = try sandbox.runner(Self.provider())
        await expectRefusal({ if case .noDevelopmentPass = $0 { true } else { false } }) { try await gate(runner) }
        // A development run below 95 % does not open the gate either.
        let failing = try sandbox.runner(Self.provider(wrong: [Self.pairs[0].0]))
        _ = try QuillBenchCLI.save(try await failing.run(RunOptions(profiles: [.spelling], models: [Self.device], repeats: 1)), paths: sandbox.paths)
        await expectRefusal({ if case .noDevelopmentPass = $0 { true } else { false } }) { try await gate(runner) }
    }

    // MARK: Log, sealed failures, confirmation

    @Test("a gate run appends to the gate log, seals failures outside the repository and prints only verdicts")
    func logAndSealed() async throws {
        let sandbox = try Sandbox()
        try await sandbox.passDevelopment(try sandbox.runner(Self.provider()))
        let runner = try sandbox.runner(Self.provider(wrong: [Self.pairs[1].0]))
        let printed = LinesBox()
        var options = GateOptions(profiles: [.spelling], models: [Self.device])
        options.label = "gate-1"
        let report = try await runner.gate(options, log: { printed.append($0) })
        #expect(report.entries.first?.verdict == "not ready")
        #expect(GateLog.load(runner.gateLogURL).entries.count == 1)
        let sealed = sandbox.paths.sealed.appendingPathComponent("gate-1.json")
        #expect(FileManager.default.fileExists(atPath: sealed.path))
        #expect(sealed.path.hasPrefix(sandbox.paths.support.path), "sealed failures live outside the repository data")
        let output = printed.lines.joined(separator: "\n")
        #expect(!output.contains(Self.pairs[1].0) && !output.contains("Best regards"), "no case text is printed")
        #expect(output.contains("not ready"))
    }

    @Test("ready needs two consecutive passing runs on the same prompt hash")
    func confirmation() async throws {
        let sandbox = try Sandbox()
        let runner = try sandbox.runner(Self.provider())
        try await sandbox.passDevelopment(runner)
        #expect(try await gate(runner, label: "g1").entries.first?.verdict == "ready (unconfirmed)")
        #expect(try await gate(runner, label: "g2").entries.first?.verdict == "ready (confirmed)")
    }

    // MARK: Counted runs

    private func seedLog(_ runner: BenchRunner, count: Int, counted: Bool = true, release: Bool = false,
                         lockHash: String? = nil, evaluationVersion: Int = RewriteKitVersion.evaluation) throws {
        var log = GateLog.load(runner.gateLogURL)
        for index in 0..<count {
            log.entries.append(GateLog.Entry(
                date: Date(), label: "seed-\(index)", profile: .spelling, model: Self.device.description,
                identity: Self.device.canonicalIdentity, promptHash: "old", gateVersion: 1, evaluationVersion: evaluationVersion,
                lockHash: lockHash ?? runner.lockHash(), judge: nil, counted: counted, release: release,
                verdict: counted ? "not ready" : "void", reasons: [], metrics: nil))
        }
        try log.save(runner.gateLogURL)
    }

    @Test("the ninth counted run is refused; infrastructure failures do not count")
    func countedRuns() async throws {
        let sandbox = try Sandbox()
        let runner = try sandbox.runner(Self.provider())
        try await sandbox.passDevelopment(runner)
        try seedLog(runner, count: 5, counted: false)
        try seedLog(runner, count: 7)
        _ = try await gate(runner, label: "eighth")
        await expectRefusal({ if case .countedRunsExhausted = $0 { true } else { false } }) { try await gate(runner, label: "ninth") }
    }

    @Test("the count resets when the lock changes and when the evaluation version changes")
    func countResets() async throws {
        let sandbox = try Sandbox()
        let runner = try sandbox.runner(Self.provider())
        try await sandbox.passDevelopment(runner)
        try seedLog(runner, count: 8, lockHash: "an-earlier-lock")
        try seedLog(runner, count: 8, evaluationVersion: RewriteKitVersion.evaluation - 1)
        #expect(try await gate(runner).entries.first?.counted == true)
    }

    @Test("the two release runs are usable only with --release")
    func releaseRuns() async throws {
        let sandbox = try Sandbox()
        let runner = try sandbox.runner(Self.provider())
        try await sandbox.passDevelopment(runner)
        try seedLog(runner, count: 8)
        await expectRefusal({ if case .countedRunsExhausted = $0 { true } else { false } }) { try await gate(runner) }
        #expect(try await gate(runner, release: true, label: "release-1").entries.first?.release == true)
        _ = try await gate(runner, release: true, label: "release-2")
        await expectRefusal({ if case .releaseRunsExhausted = $0 { true } else { false } }) {
            try await gate(runner, release: true, label: "release-3")
        }
    }

    @Test("rate limiting from the CLI voids the run as not evaluated, without counting it")
    func rateLimitedVoid() async throws {
        let sandbox = try Sandbox()
        try await sandbox.passDevelopment(try sandbox.runner(Self.provider()))
        let runner = try sandbox.runner(Self.provider(rateLimited: true))
        let entry = try #require(try await gate(runner).entries.first)
        #expect(entry.counted == false)
        #expect(entry.reasons.first == "not evaluated (CLI rate-limited)")
    }

    // MARK: References and parking

    @Test("an evaluation-version change re-checks references and parks failing cases, by id")
    func parking() async throws {
        var holdout = Self.holdoutCases
        holdout.append(Self.fixture("spelling-hold-004", input: "see u at the office",
                                    reference: "Hello! See you at the office. Best regards.", categories: [.english]))
        let sandbox = try Sandbox(holdout: holdout)
        let tools = HoldoutTools(paths: sandbox.paths)
        try tools.writeParked(.init(evaluationVersion: RewriteKitVersion.evaluation - 1, ids: []))
        let parked = tools.ensureReferencesChecked()
        #expect(parked == ["spelling-hold-004"])
        let runner = try sandbox.runner(Self.provider())
        #expect(!runner.loadHoldout(profiles: [.spelling], excluding: parked).contains { $0.benchCase.id == "spelling-hold-004" })
        #expect(try tools.checkReferences() == ["spelling-hold-004"])
    }

    @Test("parked cases that leave a critical category uncovered leave the profile without a verdict")
    func parkingCoverage() async throws {
        let sandbox = try Sandbox()
        let runner = try sandbox.runner(Self.provider())
        try await sandbox.passDevelopment(runner)
        try HoldoutTools(paths: sandbox.paths).writeParked(.init(evaluationVersion: RewriteKitVersion.evaluation, ids: ["spelling-hold-002"]))
        let entry = try #require(try await gate(runner).entries.first)
        #expect(entry.counted == false)
        #expect(entry.reasons.first?.contains("parked") == true)
    }

    // MARK: The verdict logic

    private func run(_ id: String, critical: Bool = false, pass: Bool = true, similarity: Double = 0.95,
                     judge: JudgeScores? = nil, infrastructure: String? = nil) -> CaseRun {
        CaseRun(caseID: id, profile: .work, model: Self.device, repeatIndex: 0, personal: false, critical: critical,
                promptHash: "h", state: pass ? "ready" : "flagged", output: "x", failedChecks: pass ? [] : ["G6"],
                checkDetails: [:], hardPass: pass, infrastructureFailure: infrastructure, similarity: similarity,
                judge: judge, judgeFailure: nil, latencyMilliseconds: 1, inputTokens: nil, outputTokens: nil, cost: 0,
                strippedPreamble: false, attempts: 1)
    }

    @Test("verdict logic: spelling-only thresholds")
    func spellingVerdicts() throws {
        let gate = try GateFile.load(Self.realData.appendingPathComponent("gate-v1.json"))
        let passing = (0..<20).map { run("c\($0)") }
        #expect(GateVerdict.compute(passing, scope: .spellingOnly, gate: gate).0 == .pass)
        // 19 of 20 = 95 % passes; 18 of 20 does not.
        #expect(GateVerdict.compute(passing.dropLast() + [run("x", pass: false)], scope: .spellingOnly, gate: gate).0 == .pass)
        if case .fail = GateVerdict.compute(passing.dropLast(2) + [run("x", pass: false), run("y", pass: false)], scope: .spellingOnly, gate: gate).0 {} else {
            Issue.record("90 % must fail")
        }
        if case .fail = GateVerdict.compute(passing.dropLast() + [run("c", critical: true, pass: false)], scope: .spellingOnly, gate: gate).0 {} else {
            Issue.record("a critical case failing one repeat must fail")
        }
        if case .fail = GateVerdict.compute(passing.map { var r = $0; r.similarity = 0.8; return r }, scope: .spellingOnly, gate: gate).0 {} else {
            Issue.record("mean similarity 0.80 must fail")
        }
        if case .void = GateVerdict.compute(passing + [run("i", infrastructure: "network")], scope: .spellingOnly, gate: gate).0 {} else {
            Issue.record("an infrastructure failure voids the run")
        }
    }

    @Test("verdict logic: rewrite thresholds, the judge and the critical meaning rule")
    func rewriteVerdicts() throws {
        let gate = try GateFile.load(Self.realData.appendingPathComponent("gate-v1.json"))
        let good = JudgeScores(meaning: 5, profileMatch: 4, nothingAdded: 5, fluency: 4)
        let passing = (0..<10).map { run("c\($0)", judge: good) }
        #expect(GateVerdict.compute(passing, scope: .rewrite, gate: gate).0 == .pass)
        if case .void = GateVerdict.compute(passing.map { var r = $0; r.judge = nil; return r }, scope: .rewrite, gate: gate).0 {} else {
            Issue.record("a rewrite profile without a judge is not evaluated")
        }
        let lowMean = JudgeScores(meaning: 4, profileMatch: 4, nothingAdded: 4, fluency: 3.8)
        if case .fail = GateVerdict.compute(passing.map { var r = $0; r.judge = lowMean; return r }, scope: .rewrite, gate: gate).0 {} else {
            Issue.record("judge mean 3.95 must fail")
        }
        let lowDimension = JudgeScores(meaning: 5, profileMatch: 5, nothingAdded: 5, fluency: 3.4)
        if case .fail = GateVerdict.compute(passing.map { var r = $0; r.judge = lowDimension; return r }, scope: .rewrite, gate: gate).0 {} else {
            Issue.record("a dimension below 3.5 must fail")
        }
        let inverted = run("critical", critical: true, judge: JudgeScores(meaning: 2, profileMatch: 5, nothingAdded: 5, fluency: 5))
        if case .fail(let reasons) = GateVerdict.compute(passing.dropLast() + [inverted], scope: .rewrite, gate: gate).0 {
            #expect(reasons.contains { $0.contains("meaning") })
        } else {
            Issue.record("a critical case with meaning ≤ 2 must fail")
        }
    }

    @Test("the rewrite-profile rule for already-correct cases lives in the change expectation, judge included")
    func alreadyCorrectRewrite() {
        let correct = BenchCase(id: "work-hold-009", profile: .work, language: "en", categories: [.alreadyCorrect], critical: true,
                                input: "The quarterly report is attached and the figures match the ones we agreed on last week.",
                                expectChange: false, references: ["The quarterly report is attached and the figures match the ones we agreed on last week."])
        let polished = GenerationState.ready(text: "The quarterly report is attached, and the figures match the ones we agreed on last week.", flags: [])
        #expect(Evaluation.evaluate(correct, state: polished, scope: .rewrite,
                                    judge: JudgeScores(meaning: 5, profileMatch: 5, nothingAdded: 5, fluency: 5)).hardChecksPassed)
        #expect(!Evaluation.evaluate(correct, state: polished, scope: .rewrite,
                                     judge: JudgeScores(meaning: 3, profileMatch: 5, nothingAdded: 5, fluency: 5)).hardChecksPassed)
    }

    // MARK: Holdout tools

    @Test("holdout add and retire update the lock and report ids only")
    func addAndRetire() async throws {
        let sandbox = try Sandbox()
        let tools = HoldoutTools(paths: sandbox.paths)
        try tools.writeLock()
        let before = try String(contentsOf: sandbox.paths.holdoutLock, encoding: .utf8)
        let source = sandbox.paths.support.appendingPathComponent("new.json")
        try FileManager.default.createDirectory(at: sandbox.paths.support, withIntermediateDirectories: true)
        try JSONEncoder().encode([Self.fixture("spelling-hold-010", input: "a new input here", reference: "A new input here.", categories: [.english])])
            .write(to: source)
        #expect(try tools.add(from: source) == ["spelling-hold-010"])
        let afterAdd = try String(contentsOf: sandbox.paths.holdoutLock, encoding: .utf8)
        #expect(afterAdd != before)
        #expect(tools.lockMismatches().isEmpty)
        try tools.retire("spelling-hold-010", reason: "a wrong mustKeep")
        #expect(try tools.cases(.spelling).first { $0.id == "spelling-hold-010" }?.isRetired == true)
        #expect(try String(contentsOf: sandbox.paths.holdoutLock, encoding: .utf8) != afterAdd)
        #expect(throws: HoldoutTools.Failure.badID("spelling-dev-001")) { try tools.retire("spelling-dev-001", reason: "x") }
        // A holdout file changed by hand no longer matches the lock.
        try "[]".write(to: sandbox.paths.holdoutCases.appendingPathComponent("spelling.json"), atomically: true, encoding: .utf8)
        #expect(tools.lockMismatches() == ["cases/holdout/spelling.json"])
    }

    @Test("baseline refuses a run that used a personal case")
    func baselineRefusesPersonal() async throws {
        let sandbox = try Sandbox()
        let runner = try sandbox.runner(Self.provider())
        let personal = sandbox.paths.personalCases
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        try JSONEncoder().encode(Self.devCases).write(to: personal.appendingPathComponent("mine.json"))
        var options = RunOptions(profiles: [.spelling], models: [Self.device], repeats: 1)
        options.caseDirectories = [personal]
        options.label = "personal"
        _ = try QuillBenchCLI.save(try await runner.run(options), paths: sandbox.paths)
        #expect(throws: ReadinessTools.Failure.personalCases("personal")) { try ReadinessTools(paths: sandbox.paths).baseline("personal") }
        options.caseDirectories = []
        options.label = "committed"
        _ = try QuillBenchCLI.save(try await runner.run(options), paths: sandbox.paths)
        #expect(throws: Never.self) { try ReadinessTools(paths: sandbox.paths).baseline("committed") }
    }

    @Test("export-readiness keys entries by canonical model identity and evaluation version, gate verdicts first")
    func exportReadiness() async throws {
        let sandbox = try Sandbox()
        let runner = try sandbox.runner(Self.provider())
        var options = RunOptions(profiles: [.spelling], models: [Self.device], repeats: 1)
        options.label = "dev"
        _ = try QuillBenchCLI.save(try await runner.run(options), paths: sandbox.paths)
        try ReadinessTools(paths: sandbox.paths).baseline("dev")
        _ = try await gate(runner, label: "g1")
        _ = try await gate(runner, label: "g2")
        let file = try ReadinessTools(paths: sandbox.paths).exportReadiness()
        let entry = try #require(file.entries.first)
        #expect(file.entries.count == 1, "the gate verdict replaces the development one for the same key")
        #expect(entry.model == Self.device.canonicalIdentity)
        #expect(entry.model.hasPrefix("apple/on-device@"))
        #expect(entry.evaluationVersion == RewriteKitVersion.evaluation)
        #expect(entry.verdict == "ready (confirmed)" && entry.label == "works well")
        #expect(ReadinessTools.label(for: "ready (unconfirmed)") == "may need review")
        #expect(ReadinessTools.label(for: "not ready (development 42 %)") == "not recommended")
        #expect(ReadinessTools.label(for: "not evaluated (CLI rate-limited)") == "not evaluated")
    }

    @Test("export-readiness keeps the macOS major a baseline was measured on")
    func exportKeepsMeasuredIdentity() async throws {
        let sandbox = try Sandbox()
        let runner = try sandbox.runner(Self.provider())
        var options = RunOptions(profiles: [.spelling], models: [Self.device], repeats: 1)
        options.label = "dev"
        let report = try await runner.run(options)
        #expect(report.summaries.first?.identity == Self.device.canonicalIdentity)
        _ = try QuillBenchCLI.save(report, paths: sandbox.paths)
        try ReadinessTools(paths: sandbox.paths).baseline("dev")

        // A baseline measured on an older macOS, read on this one.
        let url = sandbox.paths.baselines.appendingPathComponent("dev.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var summaries = try #require(object["summaries"] as? [[String: Any]])
        summaries[0]["identity"] = "apple/on-device@25"
        object["summaries"] = summaries
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let file = try ReadinessTools(paths: sandbox.paths).exportReadiness()
        #expect(file.entries.map(\.model) == ["apple/on-device@25"])
    }
}

final class LinesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.withLock { stored.append(line) } }
    var lines: [String] { lock.withLock { stored } }
}
