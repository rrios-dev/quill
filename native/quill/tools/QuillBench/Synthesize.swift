import Foundation
import ModelKit
import SynthesisKit

/// `quill-bench synthesize <transcript> --model p:m [--focus work|analysis|brief] [--context N]`
///
/// The meeting-synthesis spike (MEETINGS.md, S3). A hosted run honours the owner-approved
/// budget like every other hosted command: an upper bound is checked before the first
/// request and the actual cost is appended to the ledger.
extension QuillBenchCLI {
    static func synthesize(_ args: Arguments, paths: BenchPaths, environment: any BenchEnvironment) async throws -> Int32 {
        guard let path = args.positional.first, let spec = args.value("model").flatMap(ModelSpec.init) else {
            print("usage: quill-bench synthesize <transcript> --model provider:model [--focus work|analysis|brief] [--context N]")
            return 2
        }
        let focusID = args.value("focus") ?? "work"
        guard let focus = SynthesisFocus.builtIns.first(where: { $0.id == focusID }) else {
            print("unknown focus \(focusID); built-ins: \(SynthesisFocus.builtIns.map(\.id).joined(separator: ", "))")
            return 2
        }
        let transcript = try String(contentsOfFile: path, encoding: .utf8)
        let provider = environment.provider(for: spec)
        var context = args.int("context")
        if context == nil {
            context = try? await provider.models().first(where: { $0.id == spec.model })?.contextTokens
        }

        let pricing = try PriceTable.load(paths.prices).pricing(for: spec)
        if !spec.isOnDevice {
            guard let pricing else {
                print("refused: \(spec) has no price in prices.json")
                return 1
            }
            let approved = ApprovedBudget.load(paths.budget)
            let spent = Ledger.load(paths.ledger).total
            // Upper bound: the transcript twice (condensed, then its notes) plus instructions,
            // and the full output allowance for every request.
            let inputTokens = Int(Double(transcript.count) / 3.5) * 2 + 4_000
            let upper = pricing.cost(of: TokenUsage(inputTokens: inputTokens, outputTokens: 2_000 * 4))
            guard upper <= approved.perRun, spent + upper <= approved.total else {
                print(String(format: "refused: upper bound %.4f $ with %.2f $ spent of %.2f $ approved", upper, spent, approved.total))
                return 1
            }
            print(String(format: "budget: upper bound %.4f $ (spent %.2f $ of %.2f $)", upper, spent, approved.total))
        }

        let outcome = try await Synthesizer(provider: provider, model: spec.model, contextTokens: context)
            .synthesize(transcript: transcript, focus: focus)
        let cost = pricing?.cost(of: outcome.usage) ?? 0
        print("model: \(spec)  focus: \(focus.id)  context: \(context.map(String.init) ?? "unknown")")
        print("requests: \(outcome.requests)  tokens in/out: \(outcome.usage.inputTokens)/\(outcome.usage.outputTokens)  latency: \(outcome.latency)  finish: \(outcome.finishReason)")
        print(String(format: "cost: %.5f $", cost))
        print("--- synthesis ---")
        print(outcome.text)

        if !spec.isOnDevice {
            try Ledger.append(
                Ledger.Entry(date: Date(), label: "synthesis-\(focus.id)", command: "synthesize \(spec)", cost: cost),
                to: paths.ledger
            )
        }
        try FileManager.default.createDirectory(at: paths.results, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let name = "\(stamp)-synthesis-\(focus.id)-\(spec.model.rawValue.replacingOccurrences(of: "/", with: "_")).md"
        try outcome.text.write(to: paths.results.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return 0
    }
}
