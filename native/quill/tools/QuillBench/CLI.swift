import Foundation
import ModelKit
import RewriteKit

/// The real world: Keychain keys in the bench's own service, real transports, real sleeps.
struct LiveBenchEnvironment: BenchEnvironment {
    /// The bench's Keychain service — fixed, never the app's (ARCHITECTURE §4.2).
    static let keychainService = "quill.bench"
    let credentials = KeychainCredentialStore(service: LiveBenchEnvironment.keychainService)

    func provider(for spec: ModelSpec) -> any ModelProvider {
        switch spec.provider.rawValue {
        case "apple.on-device": AppleOnDeviceProvider()
        case "openai": ChatCompletionsProvider.openAI(credentials: credentials)
        case "vercel-ai-gateway": ChatCompletionsProvider.vercelAIGateway(credentials: credentials)
        default: ChatCompletionsProvider.openRouter(credentials: credentials)
        }
    }

    func hasKey(for provider: ProviderID) -> Bool {
        ((try? credentials.secret(for: provider)) ?? nil)?.isEmpty == false
    }

    func sleep(for duration: Duration) async { try? await Task.sleep(for: duration) }
}

/// Command-line options as `--name value` pairs and `--flag`s.
struct Arguments {
    var command: String
    var positional: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    static let flagNames: Set<String> = ["dry-run", "allow-unpriced", "release"]

    init(_ arguments: [String]) {
        command = arguments.first ?? ""
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if Self.flagNames.contains(name) {
                    flags.insert(name)
                } else if index + 1 < arguments.count {
                    values[name, default: []].append(arguments[index + 1])
                    index += 1
                }
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }

    func value(_ name: String) -> String? { values[name]?.last }

    /// Comma-separated and repeated values alike.
    func list(_ name: String) -> [String] {
        (values[name] ?? []).flatMap { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
    }

    func double(_ name: String) -> Double? { value(name).flatMap(Double.init) }
    func int(_ name: String) -> Int? { value(name).flatMap(Int.init) }
}

enum QuillBenchCLI {
    static func main(_ arguments: [String], environment: any BenchEnvironment = LiveBenchEnvironment()) async -> Int32 {
        let args = Arguments(arguments)
        guard let dataPath = args.value("data") else {
            print(usage)
            return args.command.isEmpty ? 0 : 64
        }
        let paths = BenchPaths.standard(data: URL(fileURLWithPath: dataPath, isDirectory: true))
        do {
            switch args.command {
            case "run": return try await run(args, paths: paths, environment: environment)
            case "burst": return await burst(args, environment: environment, paths: paths)
            case "compare": return compare(args, paths: paths)
            case "keys": return keys(args)
            case "gate": return try await gate(args, paths: paths, environment: environment)
            case "baseline": return baseline(args, paths: paths)
            case "export-readiness": return exportReadiness(paths: paths)
            case "check-references": return checkReferences(paths: paths)
            case "holdout": return holdout(args, paths: paths)
            default:
                print(usage)
                return 64
            }
        } catch let refusal as GateRefusal {
            FileHandle.standardError.write(Data("\(refusal)\n".utf8))
            return 2
        } catch let refusal as BenchRefusal {
            FileHandle.standardError.write(Data("\(refusal)\n".utf8))
            return 2
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    /// The judge grades with the rubric of the gate file in use — the newest one unless
    /// `--gate-file` names another — so a development run and a gate run of the same
    /// profile hear the same definition of it (BENCH §1.2).
    static func makeRunner(paths: BenchPaths, environment: any BenchEnvironment, gateFile: String? = nil) throws -> BenchRunner {
        let name = gateFile ?? latestGateFile(paths: paths)
        let gate = try? GateFile.load(paths.data.appendingPathComponent(name))
        let rubricFile = gate?.rubric.file ?? "judge/rubric-v1.md"
        let rubric = (try? String(contentsOf: paths.data.appendingPathComponent(rubricFile), encoding: .utf8))
            .map { JudgeClient.Rubric(text: $0, version: gate?.rubric.version ?? 1) }
        return BenchRunner(paths: paths, environment: environment, engine: try GenerationEngine(),
                           composer: try PromptComposer(), prices: try PriceTable.load(paths.prices), rubric: rubric)
    }

    /// `gate-v<n>.json` with the highest n; a rubric bump adds one (BENCH §2.3).
    static func latestGateFile(paths: BenchPaths) -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.data.path)) ?? []
        let versions = names.compactMap { name -> Int? in
            guard name.hasPrefix("gate-v"), name.hasSuffix(".json") else { return nil }
            return Int(name.dropFirst("gate-v".count).dropLast(".json".count))
        }
        return "gate-v\(versions.max() ?? 1).json"
    }

    static func run(_ args: Arguments, paths: BenchPaths, environment: any BenchEnvironment) async throws -> Int32 {
        let profiles = args.list("profiles").compactMap(BuiltInProfile.init(rawValue:))
        let models = args.list("models").compactMap(ModelSpec.init)
        guard !profiles.isEmpty, !models.isEmpty else {
            print("run needs --profiles and --models")
            return 64
        }
        var options = RunOptions(profiles: profiles, models: models)
        options.repeats = args.int("repeat") ?? 3
        options.judge = args.value("judge").flatMap(ModelSpec.init)
        options.dryRun = args.flags.contains("dry-run")
        options.budget = args.double("budget")
        options.totalBudget = args.double("total-budget")
        options.allowUnpriced = args.flags.contains("allow-unpriced")
        options.maxRequests = args.int("max-requests")
        options.label = args.value("label") ?? "run"
        options.caseDirectories = args.list("cases").map { URL(fileURLWithPath: $0, isDirectory: true) }

        let runner = try makeRunner(paths: paths, environment: environment)
        let report = try await runner.run(options)
        if !report.dryRun {
            let url = try save(report, paths: paths)
            print(markdown(report))
            print("results: \(url.path)")
        }
        return report.aborted == nil ? 0 : 3
    }

    static func save(_ report: RunReport, paths: BenchPaths) throws -> URL {
        try FileManager.default.createDirectory(at: paths.results, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: report.date).replacingOccurrences(of: ":", with: "-")
        let url = paths.results.appendingPathComponent("\(stamp)-\(report.label).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }

    /// The Markdown summary of BENCH §4 for `run`: per profile × model, then every failed check.
    static func markdown(_ report: RunReport) -> String {
        var text = "## \(report.label) — \(report.runs.count) runs, cost $\(String(format: "%.4f", report.cost))"
        if let aborted = report.aborted { text += "\n\n**Aborted**: \(aborted)" }
        text += "\n\n| profile | model | hard | critical | sim | judge | p50 | cost | preambles cut | verdict |\n|---|---|---|---|---|---|---|---|---|---|\n"
        for summary in report.summaries {
            // Truncated, as the verdict is: 94.6 % reads 94 %, below the 95 % bar.
            text += "| \(summary.profile.rawValue) | \(summary.model) | \(Int((summary.hardPassRate * 100).rounded(.down))) % | "
            text += summary.criticalFailures.isEmpty ? "pass" : "\(summary.criticalFailures.count) fail"
            text += " | " + (summary.meanSimilarity.map { String(format: "%.2f", $0) } ?? "–")
            text += " | " + (summary.judgeMean.map { String(format: "%.1f", $0) } ?? "–")
            text += " | " + (summary.p50LatencyMilliseconds.map { String(format: "%.1f s", $0 / 1000) } ?? "–")
            text += String(format: " | $%.4f | %d | %@ |\n", summary.cost, summary.strippedPreambles, summary.developmentVerdict)
        }
        let failed = report.runs.filter { !$0.hardPass }
        if !failed.isEmpty {
            text += "\n### Failed checks\n"
            for run in failed {
                let reason = run.infrastructureFailure.map { "infrastructure: \($0)" }
                    ?? run.failedChecks.map { check in run.checkDetails[check].map { "\(check) (\($0))" } ?? check }.joined(separator: ", ")
                text += "\n- `\(run.caseID)` #\(run.repeatIndex) \(run.model): \(reason)"
                if let output = run.output { text += "\n  > " + output.replacingOccurrences(of: "\n", with: "\n  > ") }
            }
        }
        return text
    }

    // MARK: gate and the holdout's tools

    static func gate(_ args: Arguments, paths: BenchPaths, environment: any BenchEnvironment) async throws -> Int32 {
        let profiles = args.list("profiles").compactMap(BuiltInProfile.init(rawValue:))
        let models = args.list("models").compactMap(ModelSpec.init)
        guard !profiles.isEmpty, !models.isEmpty else {
            print("gate needs --profiles and --models")
            return 64
        }
        var options = GateOptions(profiles: profiles, models: models)
        options.repeats = args.int("repeat")
        options.judge = args.value("judge").flatMap(ModelSpec.init)
        options.budget = args.double("budget")
        options.totalBudget = args.double("total-budget")
        options.label = args.value("label") ?? "gate"
        options.release = args.flags.contains("release")
        options.gateFile = args.value("gate-file") ?? latestGateFile(paths: paths)
        let runner = try makeRunner(paths: paths, environment: environment, gateFile: options.gateFile)
        let report = try await runner.gate(options)
        let url = try saveGate(report, paths: paths)
        print("verdicts: \(url.path) (per-case failures are sealed for the owner)")
        return 0
    }

    static func saveGate(_ report: GateReport, paths: BenchPaths) throws -> URL {
        try FileManager.default.createDirectory(at: paths.results, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: report.date).replacingOccurrences(of: ":", with: "-")
        let url = paths.results.appendingPathComponent("\(stamp)-\(report.label).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }

    static func baseline(_ args: Arguments, paths: BenchPaths) -> Int32 {
        guard let label = args.positional.first else { print("baseline <label>"); return 64 }
        do {
            let url = try ReadinessTools(paths: paths).baseline(label)
            print("baseline: \(url.path)")
            return 0
        } catch {
            print("\(error)")
            return 2
        }
    }

    static func exportReadiness(paths: BenchPaths) -> Int32 {
        do {
            let file = try ReadinessTools(paths: paths).exportReadiness()
            print("readiness.json: \(file.entries.count) entries")
            return 0
        } catch {
            print("\(error)")
            return 1
        }
    }

    static func checkReferences(paths: BenchPaths) -> Int32 {
        do {
            let parked = try HoldoutTools(paths: paths).checkReferences()
            print(parked.isEmpty ? "every holdout reference passes" : "parked for the owner: " + parked.joined(separator: ", "))
            return parked.isEmpty ? 0 : 3
        } catch {
            print("\(error)")
            return 1
        }
    }

    /// `holdout add --from <file>` and `holdout retire <id> --reason …`, owner-initiated
    /// (BENCH §2.3). Both regenerate the lock and print ids only.
    static func holdout(_ args: Arguments, paths: BenchPaths) -> Int32 {
        let tools = HoldoutTools(paths: paths)
        do {
            switch args.positional.first {
            case "add":
                guard let source = args.value("from") else { print("holdout add --from <cases.json>"); return 64 }
                let added = try tools.add(from: URL(fileURLWithPath: source))
                print("added: \(added.joined(separator: ", ")); lock regenerated")
            case "retire":
                guard args.positional.count == 2, let reason = args.value("reason") else {
                    print("holdout retire <id> --reason <text>")
                    return 64
                }
                try tools.retire(args.positional[1], reason: reason)
                print("retired: \(args.positional[1]); lock regenerated")
            case "lock":
                try tools.writeLock()
                print("lock written")
            default:
                print("holdout add|retire|lock")
                return 64
            }
            print("commit with a `Holdout-Change: <what>; approved by owner <date>` trailer (BENCH §2.3)")
            return 0
        } catch {
            print("\(error)")
            return 2
        }
    }

    // MARK: burst

    /// `burst --model apple.on-device:system --calls 30`: the CLI's rate-limit measurement
    /// (PROVIDERS §8), with the one-shot `generate` the bench uses.
    static func burst(_ args: Arguments, environment: any BenchEnvironment, paths: BenchPaths) async -> Int32 {
        guard let spec = args.value("model").flatMap(ModelSpec.init), spec.isOnDevice else {
            print("burst measures the on-device model: --model apple.on-device:system")
            return 64
        }
        let calls = args.int("calls") ?? 30
        let retries = Counter()
        let provider = AppleOnDeviceProvider(onRetry: { retries.increment() })
        let request = GenerationRequest(
            model: spec.model, instructions: "Fix the spelling of the user's text. Return only the corrected text.",
            input: "teh meeting is tomorow at 5, see u there", options: GenerationOptions(temperature: 0))
        var failures: [String: Int] = [:]
        var latencies: [Double] = []
        var firstThrottled: Int?
        let clock = ContinuousClock()
        for index in 1...calls {
            let before = retries.value
            let start = clock.now
            do {
                _ = try await provider.generate(request)
            } catch let error as ProviderError {
                failures["\(error.code)", default: 0] += 1
            } catch {
                failures["\(error)", default: 0] += 1
            }
            latencies.append(BenchRunner.milliseconds(clock.now - start))
            if (retries.value > before || failures.values.reduce(0, +) > 0), firstThrottled == nil { firstThrottled = index }
        }
        let sorted = latencies.sorted()
        let succeeded = calls - failures.values.reduce(0, +)
        print(String(format: "burst: %d/%d ok, %d retried, failures %@, first throttled call %@, p50 %.0f ms, max %.0f ms",
                     succeeded, calls, retries.value, "\(failures)", firstThrottled.map(String.init) ?? "none",
                     sorted[sorted.count / 2], sorted.last ?? 0))
        return failures.isEmpty ? 0 : 3
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    // MARK: compare

    static func latestResult(labelled label: String, paths: BenchPaths) -> RunReport? {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.results, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.lastPathComponent.hasSuffix("-\(label).json") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .lazy.compactMap { try? decoder.decode(RunReport.self, from: Data(contentsOf: $0)) }.first
    }

    static func compare(_ args: Arguments, paths: BenchPaths) -> Int32 {
        guard args.positional.count == 2,
              let before = latestResult(labelled: args.positional[0], paths: paths),
              let after = latestResult(labelled: args.positional[1], paths: paths) else {
            print("compare <label> <label>: both runs must exist in the results folder")
            return 64
        }
        print("| profile | model | hard before → after | sim before → after | judge before → after |\n|---|---|---|---|---|")
        for summary in after.summaries {
            let old = before.summaries.first { $0.profile == summary.profile && $0.model == summary.model }
            func percent(_ value: Double?) -> String { value.map { "\(Int(($0 * 100).rounded(.down))) %" } ?? "–" }
            func number(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "–" }
            print("| \(summary.profile.rawValue) | \(summary.model) | \(percent(old?.hardPassRate)) → \(percent(summary.hardPassRate)) | \(number(old?.meanSimilarity)) → \(number(summary.meanSimilarity)) | \(number(old?.judgeMean)) → \(number(summary.judgeMean)) |")
        }
        return 0
    }

    // MARK: keys

    /// `keys set <provider>` reads the key from the terminal without echo and stores it in
    /// the bench's Keychain service; `keys remove <provider>` deletes it.
    static func keys(_ args: Arguments) -> Int32 {
        guard args.positional.count == 2 else {
            print("keys set|remove <provider>")
            return 64
        }
        let store = KeychainCredentialStore(service: LiveBenchEnvironment.keychainService)
        let provider = ProviderID(rawValue: args.positional[1])
        do {
            switch args.positional[0] {
            case "set":
                var buffer = [CChar](repeating: 0, count: 512)
                guard let raw = readpassphrase("API key for \(provider): ", &buffer, buffer.count, RPP_ECHO_OFF | RPP_REQUIRE_TTY) else {
                    print("no key read")
                    return 1
                }
                let key = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
                buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
                guard !key.isEmpty else { print("empty key"); return 1 }
                try store.setSecret(key, for: provider)
                print("stored the key for \(provider) in the \(LiveBenchEnvironment.keychainService) Keychain service")
            case "remove":
                try store.removeSecret(for: provider)
                print("removed the key for \(provider)")
            default:
                print("keys set|remove <provider>")
                return 64
            }
            return 0
        } catch {
            print("Keychain error: \(error)")
            return 1
        }
    }

    static let usage = """
    usage: quill-bench <command> --data <data folder> [options]   (run it through Scripts/bench.sh)

    commands:
      run               development cases: --profiles a,b --models p:m,... [--repeat 3] [--judge p:m]
                        [--dry-run] [--budget USD] [--total-budget USD] [--allow-unpriced --max-requests N]
                        [--label name] [--cases dir,...]
      burst             --model apple.on-device:system [--calls 30]
      compare           <label> <label>
      keys              set|remove <provider>
      gate              holdout cases: --profiles --models [--judge p:m] [--repeat 3] --budget USD [--release]
      baseline          <label>
      export-readiness  regenerate readiness.json
      check-references  re-check holdout references; park failing ones (ids only)
      holdout           add --from <file> | retire <id> --reason <text> | lock

    See docs/initiatives/quill/BENCH.md §3.
    """
}
