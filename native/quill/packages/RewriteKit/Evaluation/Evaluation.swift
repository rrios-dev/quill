import Foundation
import ModelKit

/// Scores one result against a bench case (ARCHITECTURE §4.7, BENCH §1). Shared by
/// `quill-bench` and the app's Try it pane, so there is one definition of "good".
public enum Evaluation {
    /// One hard check, reported on its own.
    public struct Check: Hashable, Sendable {
        public var name: String
        public var passed: Bool
        public var detail: String?

        public init(_ name: String, _ passed: Bool, _ detail: String? = nil) {
            self.name = name
            self.passed = passed
            self.detail = detail
        }
    }

    public struct Report: Hashable, Sendable {
        /// Hard checks: every one must pass for the run to pass.
        public var checks: [Check]
        /// Set when the run failed for a reason that says nothing about quality — a
        /// network error, rate limiting, a cancellation. Never counted as a quality
        /// failure; the bench retries or voids the run (BENCH §1.1).
        public var infrastructureFailure: String?
        /// Soft, 0–1: similarity to the closest reference.
        public var referenceSimilarity: Double?
        public var judge: JudgeScores?
        /// The text evaluated: the result, or the input when nothing changed.
        public var output: String?

        public var hardChecksPassed: Bool { infrastructureFailure == nil && checks.allSatisfy(\.passed) }
        public var failedChecks: [Check] { checks.filter { !$0.passed } }
    }

    /// The guards the bench gates on (BENCH §1): G7 is the change expectation's
    /// business and G11 does not apply to bench text.
    public static let gatedGuards = ["G1", "G2", "G3", "G4", "G5", "G6", "G8", "G9", "G10", "G12", "G13"]

    public static func evaluate(
        _ benchCase: BenchCase,
        state: GenerationState,
        scope: ProfileSettings.Scope,
        judge: JudgeScores? = nil
    ) -> Report {
        var output: String?
        var flags: [GuardFlag] = []
        var checks: [Check] = []

        switch state {
        case .ready(let text, let resultFlags):
            output = text
            flags = resultFlags
        case .noChanges:
            output = benchCase.input
        case .truncated, .tooLong, .refused:
            break
        case .failed(.malformedResponse, _):
            break
        case .failed(let code, _):
            return Report(checks: [], infrastructureFailure: "\(code)", referenceSimilarity: nil, judge: judge, output: nil)
        case .cancelled:
            return Report(checks: [], infrastructureFailure: "cancelled", referenceSimilarity: nil, judge: judge, output: nil)
        case .idle, .generating:
            return Report(checks: [], infrastructureFailure: "not finished", referenceSimilarity: nil, judge: judge, output: nil)
        }

        // Guards, one check each.
        for guardID in gatedGuards {
            let raised = flags.filter { $0.guardID == guardID }
            var passed = raised.isEmpty
            var detail = raised.isEmpty ? nil : raised.map { "\($0)" }.joined(separator: "; ")
            if guardID == "G8", case .failed(.malformedResponse, _) = state { passed = false; detail = "empty answer" }
            if guardID == "G10", case .refused = state { passed = false; detail = "refused" }
            checks.append(Check(guardID, passed, detail))
        }

        // Finish reason and the pre-check.
        switch state {
        case .truncated: checks.append(Check("finish", false, "cut off by the output limit"))
        case .tooLong: checks.append(Check("finish", false, "too long for the model"))
        default: checks.append(Check("finish", true))
        }

        // mustKeep and mustNotContain, case-insensitively.
        let lowered = output?.lowercased() ?? ""
        let missing = benchCase.mustKeep.filter { !lowered.contains($0.lowercased()) }
        checks.append(Check("mustKeep", output != nil && missing.isEmpty,
                            missing.isEmpty ? nil : "missing: " + missing.joined(separator: ", ")))
        let present = benchCase.mustNotContain.filter { lowered.contains($0.lowercased()) }
        checks.append(Check("mustNotContain", output != nil && present.isEmpty,
                            present.isEmpty ? nil : "contains: " + present.joined(separator: ", ")))

        // The change expectation.
        checks.append(changeExpectation(benchCase, state: state, output: output, flags: flags, scope: scope, judge: judge))

        let similarity = output.map { text in
            benchCase.references.map { Similarity.reference(text, $0) }.max() ?? 0
        }
        return Report(checks: checks, infrastructureFailure: nil, referenceSimilarity: similarity, judge: judge, output: output)
    }

    /// `expectChange: true` must not yield `noChanges`. `false`: spelling-only profiles
    /// must yield `noChanges`; rewrite profiles pass with no flag, similarity to the
    /// input ≥ 0.9 and, when judged, a meaning score ≥ 4.
    public static func changeExpectation(
        _ benchCase: BenchCase, state: GenerationState, output: String?, flags: [GuardFlag],
        scope: ProfileSettings.Scope, judge: JudgeScores?
    ) -> Check {
        let isNoChanges = state == .noChanges
        if benchCase.expectChange {
            return Check("change", output != nil && !isNoChanges, isNoChanges ? "no changes suggested" : nil)
        }
        if scope == .spellingOnly {
            return Check("change", isNoChanges, isNoChanges ? nil : "a spelling-only profile changed correct text")
        }
        guard let output else { return Check("change", false, "no output") }
        if isNoChanges { return Check("change", true) }
        let similarity = Similarity.reference(output, benchCase.input)
        var problems: [String] = []
        if !flags.isEmpty { problems.append("flagged") }
        if similarity < 0.9 { problems.append(String(format: "similarity to the input %.2f", similarity)) }
        if let judge, judge.meaning < 4 { problems.append("meaning \(judge.meaning)") }
        return Check("change", problems.isEmpty, problems.isEmpty ? nil : problems.joined(separator: "; "))
    }
}
