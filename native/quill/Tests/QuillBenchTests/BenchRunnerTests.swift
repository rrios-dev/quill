import Foundation
import ModelKit
import Testing

@testable import QuillBench
@testable import RewriteKit

/// A provider that answers from a script and records every request.
final class FakeBenchProvider: ModelProvider, @unchecked Sendable {
    enum Reply: Sendable {
        case text(String, FinishReason, TokenUsage?)
        case error(ProviderError.Code)
    }

    let descriptor: ProviderDescriptor
    private let lock = NSLock()
    private var requests: [GenerationRequest] = []
    private var streamCount = 0
    private let script: @Sendable (GenerationRequest, Int) -> Reply

    init(id: ProviderID, onDevice: Bool = false, script: @escaping @Sendable (GenerationRequest, Int) -> Reply) {
        descriptor = ProviderDescriptor(
            id: id, displayName: id.rawValue,
            traits: ProviderTraits(execution: onDevice ? .onDevice : .remote(recipients: [.named(id.rawValue)]),
                                   cost: onDevice ? .free : .payPerUse, credential: onDevice ? .none : .apiKey,
                                   maxContextTokens: onDevice ? 4_096 : nil))
        self.script = script
    }

    var recorded: [GenerationRequest] { lock.withLock { requests } }
    var streams: Int { lock.withLock { streamCount } }

    func availability() async -> ProviderAvailability { .available }
    func models() async throws -> [ModelDescriptor] { [] }

    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error> {
        lock.withLock { streamCount += 1 }
        return AsyncThrowingStream { $0.finish(throwing: ProviderError(.server, "streaming is not used by the bench")) }
    }

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        let index = lock.withLock { () -> Int in requests.append(request); return requests.count - 1 }
        switch script(request, index) {
        case .text(let text, let finish, let usage):
            return GenerationResult(text: text, provider: descriptor.id, model: request.model, usage: usage,
                                    latency: .milliseconds(10), finishReason: finish)
        case .error(let code):
            throw ProviderError(code, "scripted", provider: descriptor.id)
        }
    }
}

final class FakeEnvironment: BenchEnvironment, @unchecked Sendable {
    let providers: [ProviderID: FakeBenchProvider]
    private let lock = NSLock()
    private var slept: [Duration] = []

    init(_ providers: [FakeBenchProvider]) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.descriptor.id, $0) })
    }

    var sleeps: [Duration] { lock.withLock { slept } }

    func provider(for spec: ModelSpec) -> any ModelProvider { providers[spec.provider]! }
    func hasKey(for provider: ProviderID) -> Bool { false }
    func sleep(for duration: Duration) async { lock.withLock { slept.append(duration) } }
}

@Suite("Bench runs, budget and keys")
struct BenchRunnerTests {
    /// A throw-away data folder: prices, an empty budget, a development case file and a
    /// holdout folder, plus a support folder for results and the ledger.
    struct Sandbox {
        let paths: BenchPaths

        init(cases: [BenchCase], prices: [String: (Double, Double)] = ["vendor/model": (1, 2), "openai/gpt-x": (3, 6)]) throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)", isDirectory: true)
            let data = root.appendingPathComponent("data", isDirectory: true)
            paths = BenchPaths(data: data, support: root.appendingPathComponent("support", isDirectory: true))
            try FileManager.default.createDirectory(at: paths.devCases, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: paths.holdoutCases, withIntermediateDirectories: true)
            try JSONEncoder().encode(cases).write(to: paths.devCases.appendingPathComponent("work.json"))
            let table = ["date": "2026-10-03", "models": prices.mapValues { ["inputPerMillion": $0.0, "outputPerMillion": $0.1] }] as [String: Any]
            try JSONSerialization.data(withJSONObject: table).write(to: paths.prices)
        }

        func runner(_ environment: FakeEnvironment) throws -> BenchRunner {
            BenchRunner(paths: paths, environment: environment, engine: try GenerationEngine(),
                        composer: try PromptComposer(), prices: try PriceTable.load(paths.prices),
                        rubric: JudgeClient.Rubric(text: "Grade it.\n\n## Profiles\n\n### work\n\nWork.\n", version: 1))
        }
    }

    static func workCase(_ index: Int, critical: Bool = false) -> BenchCase {
        BenchCase(id: "work-dev-\(String(format: "%03d", index))", profile: .work, language: "en",
                  categories: critical ? [.english, .whoDidWhat] : [.english], critical: critical,
                  input: "the report u asked for is not done yet sorry", expectChange: true,
                  references: ["The report you asked for is not done yet. Sorry."], mustKeep: ["report"])
    }

    let hosted = ModelSpec(provider: "openrouter", model: "vendor/model")
    let good = "The report you asked for is not done yet. Sorry."

    private func goodProvider(usage: TokenUsage? = TokenUsage(inputTokens: 100, outputTokens: 20)) -> FakeBenchProvider {
        let good = good
        return FakeBenchProvider(id: "openrouter") { _, _ in .text(good, .stop, usage) }
    }

    @Test("a hosted model without --budget stops before any request")
    func noBudget() async throws {
        let sandbox = try Sandbox(cases: [Self.workCase(1)])
        let provider = goodProvider()
        let runner = try sandbox.runner(FakeEnvironment([provider]))
        await #expect(throws: BenchRefusal.noBudget) {
            try await runner.run(RunOptions(profiles: [.work], models: [hosted], repeats: 1))
        }
        #expect(provider.recorded.isEmpty)
    }

    @Test("an estimate over the budget stops before any request, judge included")
    func estimateOverBudget() async throws {
        let sandbox = try Sandbox(cases: (1...5).map { Self.workCase($0) })
        let provider = goodProvider()
        let judge = FakeBenchProvider(id: "openai") { _, _ in .text("{}", .stop, nil) }
        let runner = try sandbox.runner(FakeEnvironment([provider, judge]))
        var options = RunOptions(profiles: [.work], models: [hosted], repeats: 3)
        options.budget = 0.000001
        options.totalBudget = 10
        options.judge = ModelSpec(provider: "openai", model: "gpt-x")
        do {
            _ = try await runner.run(options)
            Issue.record("expected a refusal")
        } catch {
            guard case .estimateOverBudget = error else { Issue.record("\(error)"); return }
        }
        #expect(provider.recorded.isEmpty && judge.recorded.isEmpty)

        options.dryRun = true
        options.budget = nil
        let dry = try await runner.run(options)
        #expect(dry.estimate > 0 && dry.upperBound > dry.estimate)
    }

    @Test("actual cost crossing the budget mid-run aborts it")
    func abortMidRun() async throws {
        // At $1,000/M in and $2,000/M out, a call's upper bound is ≈ $3.5, its estimate ≈ $0.5
        // and its reported usage (400 in, 20 out) $0.44 — real usage never exceeds the bound.
        let sandbox = try Sandbox(cases: (1...10).map { Self.workCase($0) }, prices: ["vendor/model": (1_000, 2_000)])
        let provider = goodProvider(usage: TokenUsage(inputTokens: 400, outputTokens: 20))
        let runner = try sandbox.runner(FakeEnvironment([provider]))
        var options = RunOptions(profiles: [.work], models: [hosted], repeats: 1)
        options.budget = 6
        options.totalBudget = 100
        // The estimate (typical cost) fits; the upper bounds of all ten calls do not.
        let report = try await runner.run(options)
        #expect(report.aborted != nil, "the run must stop when the next upper bound could pass the budget")
        #expect(report.cost <= 6)
        #expect(provider.recorded.count < 10)
        #expect(report.runs.count == provider.recorded.count)
    }

    @Test("a response without usage is charged its upper bound: one token per input character, output at the cap")
    func noUsageChargedUpperBound() async throws {
        let sandbox = try Sandbox(cases: [Self.workCase(1)])
        let provider = goodProvider(usage: nil)
        let runner = try sandbox.runner(FakeEnvironment([provider]))
        var options = RunOptions(profiles: [.work], models: [hosted], repeats: 1)
        options.budget = 1
        options.totalBudget = 10
        let report = try await runner.run(options)
        let request = try #require(provider.recorded.first)
        let cap = try #require(request.options.maxOutputTokens)
        let expected = (Double(CallCost.characters(of: request)) * 1 + Double(cap) * 2) / 1_000_000
        #expect(abs(report.cost - expected) < 1e-12)
    }

    @Test("hosted calls are capped at max(1,024, 4 × input tokens)")
    func outputCap() async throws {
        #expect(CallCost.outputCap(estimatedInputTokens: 10) == 1_024)
        #expect(CallCost.outputCap(estimatedInputTokens: 1_000) == 4_000)
        let sandbox = try Sandbox(cases: [Self.workCase(1)])
        let provider = goodProvider()
        let runner = try sandbox.runner(FakeEnvironment([provider]))
        var options = RunOptions(profiles: [.work], models: [hosted], repeats: 1)
        options.budget = 1
        options.totalBudget = 10
        _ = try await runner.run(options)
        let request = try #require(provider.recorded.first)
        #expect(request.options.maxOutputTokens == CallCost.outputCap(estimatedInputTokens: TokenEstimate.characters(in: request)))
    }

    @Test("a length finish with no visible output is retried once with double the cap, then voided")
    func hiddenReasoningRetry() async throws {
        let sandbox = try Sandbox(cases: [Self.workCase(1)])
        let provider = FakeBenchProvider(id: "openrouter") { _, _ in .text("", .length, TokenUsage(inputTokens: 10, outputTokens: 1_024)) }
        let runner = try sandbox.runner(FakeEnvironment([provider]))
        var options = RunOptions(profiles: [.work], models: [hosted], repeats: 1)
        options.budget = 1
        options.totalBudget = 10
        let report = try await runner.run(options)
        #expect(provider.recorded.count == 2)
        #expect(provider.recorded[1].options.maxOutputTokens == provider.recorded[0].options.maxOutputTokens.map { $0 * 2 })
        #expect(report.runs.first?.infrastructureFailure != nil, "never a quality failure")
        #expect(report.summaries.first?.voided == 1)
    }

    @Test("on-device calls use generate, and rate limits are retried at most 5 times with backoff")
    func onDeviceRateLimits() async throws {
        let sandbox = try Sandbox(cases: [Self.workCase(1)])
        let good = good
        let device = FakeBenchProvider(id: "apple.on-device", onDevice: true) { _, index in
            index < 3 ? .error(.rateLimited(retryAfter: nil)) : .text(good, .stop, nil)
        }
        let environment = FakeEnvironment([device])
        let runner = try sandbox.runner(environment)
        let report = try await runner.run(RunOptions(profiles: [.work], models: [ModelSpec(provider: "apple.on-device", model: "system")], repeats: 1))
        #expect(device.streams == 0, "the bench never streams")
        #expect(device.recorded.count == 4)
        #expect(environment.sleeps == [.seconds(2), .seconds(4), .seconds(8)])
        #expect(report.runs.first?.hardPass == true)

        let always = FakeBenchProvider(id: "apple.on-device", onDevice: true) { _, _ in .error(.rateLimited(retryAfter: nil)) }
        let limited = try sandbox.runner(FakeEnvironment([always]))
        let throttled = try await limited.run(RunOptions(profiles: [.work], models: [ModelSpec(provider: "apple.on-device", model: "system")], repeats: 1))
        #expect(always.recorded.count == 6, "the call and 5 retries")
        #expect(throttled.runs.first?.infrastructureFailure != nil)
    }

    @Test("dry runs without keys price models from prices.json by canonical identity")
    func dryRunPrices() async throws {
        let sandbox = try Sandbox(cases: [Self.workCase(1)])
        let openAI = FakeBenchProvider(id: "openai") { _, _ in .text("x", .stop, nil) }
        let runner = try sandbox.runner(FakeEnvironment([openAI]))
        var options = RunOptions(profiles: [.work], models: [ModelSpec(provider: "openai", model: "gpt-x")], repeats: 3)
        options.dryRun = true
        let report = try await runner.run(options)
        #expect(report.estimate > 0, "gpt-x is priced as openai/gpt-x")
        #expect(openAI.recorded.isEmpty)
        #expect(ModelSpec("openai:gpt-x")?.canonicalIdentity == "openai/gpt-x")
        #expect(ModelSpec("openrouter:anthropic/x")?.vendor == "anthropic")
    }

    @Test("run refuses holdout cases, even through --cases")
    func refusesHoldout() async throws {
        let sandbox = try Sandbox(cases: [Self.workCase(1)])
        try JSONEncoder().encode([Self.workCase(2)]).write(to: sandbox.paths.holdoutCases.appendingPathComponent("work.json"))
        let runner = try sandbox.runner(FakeEnvironment([goodProvider()]))
        var options = RunOptions(profiles: [.work], models: [hosted], repeats: 1)
        options.dryRun = true
        options.caseDirectories = [sandbox.paths.holdoutCases]
        do {
            _ = try await runner.run(options)
            Issue.record("holdout accepted")
        } catch {
            guard case .holdoutCase = error else { Issue.record("\(error)"); return }
        }
        // A copy of a holdout case elsewhere is refused by its id.
        let elsewhere = sandbox.paths.support.appendingPathComponent("copied", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        var copied = Self.workCase(3)
        copied.id = "work-hold-001"
        try JSONEncoder().encode([copied]).write(to: elsewhere.appendingPathComponent("work.json"))
        options.caseDirectories = [elsewhere]
        do {
            _ = try await runner.run(options)
            Issue.record("copied holdout accepted")
        } catch {
            guard case .holdoutCase = error else { Issue.record("\(error)"); return }
        }
    }

    @Test("a run whose upper bound would take the ledger past --total-budget is refused")
    func totalBudget() async throws {
        let sandbox = try Sandbox(cases: [Self.workCase(1)])
        try Ledger.append(.init(date: Date(), label: "earlier", command: "run", cost: 4.999), to: sandbox.paths.ledger)
        let provider = goodProvider()
        let runner = try sandbox.runner(FakeEnvironment([provider]))
        var options = RunOptions(profiles: [.work], models: [hosted], repeats: 1)
        options.budget = 1
        options.totalBudget = 5
        do {
            _ = try await runner.run(options)
            Issue.record("expected a refusal")
        } catch {
            guard case .totalBudgetExceeded = error else { Issue.record("\(error)"); return }
        }
        #expect(provider.recorded.isEmpty)
        // Without --total-budget the approved amount applies: zero until OS3.
        options.totalBudget = nil
        await #expect(throws: (any Error).self) { try await runner.run(options) }
    }

    @Test("every hosted run appends its actual cost to the ledger")
    func ledgerAppended() async throws {
        let sandbox = try Sandbox(cases: [Self.workCase(1)])
        let runner = try sandbox.runner(FakeEnvironment([goodProvider()]))
        var options = RunOptions(profiles: [.work], models: [hosted], repeats: 1)
        options.budget = 1
        options.totalBudget = 10
        options.label = "first"
        let report = try await runner.run(options)
        let ledger = Ledger.load(sandbox.paths.ledger)
        #expect(ledger.entries.count == 1)
        #expect(abs(ledger.total - report.cost) < 1e-12)
    }

    @Test("a development run below 95 % records not ready (development NN %)")
    func developmentVerdict() async throws {
        let sandbox = try Sandbox(cases: (1...4).map { Self.workCase($0) })
        let good = good
        let device = FakeBenchProvider(id: "apple.on-device", onDevice: true) { _, index in
            index == 0 ? .text("Dear team, the report is late.", .stop, nil) : .text(good, .stop, nil)
        }
        let runner = try sandbox.runner(FakeEnvironment([device]))
        let report = try await runner.run(RunOptions(profiles: [.work], models: [ModelSpec(provider: "apple.on-device", model: "system")], repeats: 1))
        #expect(report.summaries.first?.developmentVerdict == "not ready (development 75 %)")
    }

    @Test("a judge from the graded model's vendor is refused")
    func sameVendorJudge() async throws {
        let sandbox = try Sandbox(cases: [Self.workCase(1)])
        let runner = try sandbox.runner(FakeEnvironment([goodProvider()]))
        var options = RunOptions(profiles: [.work], models: [hosted], repeats: 1)
        options.judge = ModelSpec(provider: "openrouter", model: "vendor/other")
        options.dryRun = true
        do {
            _ = try await runner.run(options)
            Issue.record("same-vendor judge accepted")
        } catch {
            guard case .sameVendorJudge = error else { Issue.record("\(error)"); return }
        }
    }

    @Test("the judge's JSON is validated against the rubric's schema, with one retry")
    func judgeSchema() async throws {
        #expect(throws: Never.self) { try JudgeClient.parse(#"{"meaning":5,"profileMatch":4,"nothingAdded":5,"fluency":5,"notes":"ok"}"#).get() }
        for bad in [
            #"{"meaning":6,"profileMatch":4,"nothingAdded":5,"fluency":5,"notes":""}"#,
            #"{"meaning":4.5,"profileMatch":4,"nothingAdded":5,"fluency":5,"notes":""}"#,
            #"{"meaning":4,"profileMatch":4,"nothingAdded":5,"fluency":5}"#,
            #"{"meaning":4,"profileMatch":4,"nothingAdded":5,"fluency":5,"notes":"","extra":1}"#,
            #"{"meaning":true,"profileMatch":4,"nothingAdded":5,"fluency":5,"notes":""}"#,
            "Sure! Here are the scores.",
        ] {
            if case .success = JudgeClient.parse(bad) { Issue.record("accepted: \(bad)") }
        }
        let fenced = "```json\n{\"meaning\":4,\"profileMatch\":4,\"nothingAdded\":5,\"fluency\":5,\"notes\":\"\"}\n```"
        #expect((try? JudgeClient.parse(fenced).get()) != nil)

        let attempts = FakeBenchProvider(id: "openai") { _, index in
            index == 0 ? .text("not json", .stop, nil)
                : .text(#"{"meaning":5,"profileMatch":5,"nothingAdded":5,"fluency":4,"notes":"fine"}"#, .stop, nil)
        }
        let client = JudgeClient(spec: ModelSpec(provider: "openai", model: "gpt-x"), provider: attempts,
                                 rubric: .init(text: "Grade.\n\n## Profiles\n\n### work\n\nWork.", version: 1),
                                 pricing: ModelPricing(inputPerMillion: 1, outputPerMillion: 1))
        let verdict = await client.grade(profile: .work, gradedVendor: "vendor", input: "a", output: "b", references: ["c"],
                                         meter: SpendMeter(budget: 1, maxRequests: nil))
        guard case .success(let value) = verdict else { Issue.record("\(verdict)"); return }
        #expect(value.scores.fluency == 4)
        #expect(attempts.recorded.count == 2)
        #expect(attempts.recorded[0].instructions.contains("### work"))
    }
}
