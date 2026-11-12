import Foundation
import MeetingKit
import ModelKit
import SynthesisKit

/// `quill-bench synthesize <transcript> --model p:m [--focus <id>] [--context N]`
/// `quill-bench synthesize --meeting <id> [--meetings <folder>] --model p:m [--focus <id>]`
///
/// The meeting-synthesis spike (MEETINGS.md, S3). With `--meeting`, a meeting the app
/// saved is synthesised the way the app does it — its rendered transcript, its people
/// weighted by the focus, the user's own speaker name — from Quill's data folder (or
/// `--meetings`), so a prompt change is measured on real meetings before it ships. The
/// result stays in the bench's results folder, outside the repository. A hosted run
/// honours the owner-approved budget like every other hosted command: an upper bound is
/// checked before the first request and the actual cost is appended to the ledger.
extension QuillBenchCLI {
    static func synthesize(_ args: Arguments, paths: BenchPaths, environment: any BenchEnvironment) async throws -> Int32 {
        let ids = SynthesisFocus.builtIns.map(\.id).joined(separator: "|")
        guard args.positional.first != nil || args.value("meeting") != nil,
              let spec = args.value("model").flatMap(ModelSpec.init) else {
            print("usage: quill-bench synthesize <transcript> | --meeting <id> [--meetings <folder>] --model provider:model [--focus \(ids)] [--context N]")
            return 2
        }
        let focusID = args.value("focus") ?? "work"
        guard let focus = SynthesisFocus.builtIns.first(where: { $0.id == focusID }) else {
            print("unknown focus \(focusID); built-ins: \(SynthesisFocus.builtIns.map(\.id).joined(separator: ", "))")
            return 2
        }
        var participants: [Participant] = []
        var user: String?
        var userVoice = "Yo"
        let transcript: String
        if let meetingID = args.value("meeting") {
            let folder = args.value("meetings").map { URL(fileURLWithPath: $0) } ?? FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("dev.rrios.quill/meetings-data")
            let store = try MeetingStore(directory: folder)
            guard let id = UUID(uuidString: meetingID), let record = store.meeting(id) else {
                print("no meeting \(meetingID) in \(folder.path)")
                return 2
            }
            transcript = record.transcript.rendered()
            participants = focus.weighting.participants(store.people(in: record))
            user = record.transcript.names["me"] ?? store.ownName()
            userVoice = record.transcript.names["me"] ?? "Yo"
        } else {
            transcript = try String(contentsOfFile: args.positional[0], encoding: .utf8)
        }
        let provider = environment.provider(for: spec)
        var context = args.int("context")
        if context == nil {
            context = try? await provider.models().first(where: { $0.id == spec.model })?.contextTokens
        }

        // A plan the user already pays for costs nothing per call (BenchRunner.info).
        let onPlan = provider.descriptor.traits.cost == .includedInPlan
        let pricing = onPlan ? ModelPricing(inputPerMillion: 0, outputPerMillion: 0)
            : try PriceTable.load(paths.prices).pricing(for: spec)
        if !spec.isOnDevice, !onPlan {
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
            .synthesize(transcript: transcript, focus: focus, participants: participants, user: user,
                        userVoice: userVoice)
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
