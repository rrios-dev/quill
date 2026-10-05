import Foundation
import Testing

@testable import RewriteKit

@Suite("Evaluation")
struct EvaluationTests {
    private func benchCase(
        expectChange: Bool = true, references: [String] = ["The report is done."],
        mustKeep: [String] = ["report"], mustNotContain: [String] = ["Dear"]
    ) -> BenchCase {
        BenchCase(id: "work-dev-001", profile: .work, language: "en", categories: [.english], critical: false,
                  input: "the report is done", expectChange: expectChange, references: references,
                  mustKeep: mustKeep, mustNotContain: mustNotContain)
    }

    private func check(_ report: Evaluation.Report, _ name: String) -> Evaluation.Check? {
        report.checks.first { $0.name == name }
    }

    // MARK: Similarity, by hand

    @Test("hand-computed reference similarities")
    func similarities() {
        // Identical after lowercasing and dropping punctuation.
        #expect(Similarity.reference("The report is done.", "the report is done") == 1)
        // One substitution in four words: 1 − 1/4.
        #expect(abs(Similarity.reference("the report is ready", "the report is done") - 0.75) < 1e-12)
        // One insertion over five words: 1 − 1/5.
        #expect(abs(Similarity.reference("the report is now done", "the report is done") - 0.8) < 1e-12)
        // A comma turned into a period changes nothing.
        #expect(Similarity.reference("Yes, it is.", "Yes. It is.") == 1)
        // Nothing in common.
        #expect(Similarity.reference("alpha beta", "gamma delta epsilon") == 0)
    }

    // MARK: Each hard check on its own

    @Test("a good result passes every hard check, each reported separately")
    func allPass() {
        let report = Evaluation.evaluate(benchCase(), state: .ready(text: "The report is done.", flags: []), scope: .rewrite)
        #expect(report.hardChecksPassed)
        #expect(Set(report.checks.map(\.name)) == Set(Evaluation.gatedGuards + ["finish", "mustKeep", "mustNotContain", "change"]))
        #expect(report.referenceSimilarity == 1)
    }

    @Test("a guard flag fails that guard's check only")
    func guardFlag() {
        let report = Evaluation.evaluate(benchCase(), state: .ready(text: "The report is done.", flags: [.addedGreeting]), scope: .rewrite)
        #expect(report.failedChecks.map(\.name) == ["G6"])
    }

    @Test("a refusal fails G10; an empty answer fails G8")
    func refusalAndEmpty() {
        let refused = Evaluation.evaluate(benchCase(), state: .refused, scope: .rewrite)
        #expect(check(refused, "G10")?.passed == false)
        #expect(check(refused, "G8")?.passed == true)
        let empty = Evaluation.evaluate(benchCase(), state: .failed(.malformedResponse, partial: ""), scope: .rewrite)
        #expect(check(empty, "G8")?.passed == false)
        #expect(empty.infrastructureFailure == nil, "an empty answer is the model's failure, not the infrastructure's")
    }

    @Test("a length finish and a too-long pre-check fail the finish check")
    func finish() {
        #expect(check(Evaluation.evaluate(benchCase(), state: .truncated(partial: "The rep"), scope: .rewrite), "finish")?.passed == false)
        #expect(check(Evaluation.evaluate(benchCase(), state: .tooLong(suggestion: nil), scope: .rewrite), "finish")?.passed == false)
    }

    @Test("mustKeep and mustNotContain are checked case-insensitively")
    func anchors() {
        let missing = Evaluation.evaluate(benchCase(), state: .ready(text: "It is done.", flags: []), scope: .rewrite)
        #expect(check(missing, "mustKeep")?.passed == false)
        #expect(check(missing, "mustKeep")?.detail == "missing: report")
        let forbidden = Evaluation.evaluate(benchCase(), state: .ready(text: "dear team, the report is done.", flags: []), scope: .rewrite)
        #expect(check(forbidden, "mustNotContain")?.passed == false)
    }

    @Test("the change expectation follows BENCH §1")
    func changeExpectation() {
        // expectChange true: noChanges fails.
        #expect(check(Evaluation.evaluate(benchCase(), state: .noChanges, scope: .rewrite), "change")?.passed == false)
        // expectChange false, spelling only: anything but noChanges fails.
        let correct = benchCase(expectChange: false, references: ["the report is done"], mustKeep: [])
        #expect(check(Evaluation.evaluate(correct, state: .noChanges, scope: .spellingOnly), "change")?.passed == true)
        #expect(check(Evaluation.evaluate(correct, state: .ready(text: "The report is done.", flags: []), scope: .spellingOnly), "change")?.passed == false)
        // expectChange false, rewrite: polish allowed with similarity ≥ 0.9, no flag, meaning ≥ 4.
        #expect(check(Evaluation.evaluate(correct, state: .ready(text: "The report is done.", flags: []), scope: .rewrite), "change")?.passed == true)
        #expect(check(Evaluation.evaluate(correct, state: .ready(text: "All finished now.", flags: []), scope: .rewrite), "change")?.passed == false)
        let judged = JudgeScores(meaning: 3, profileMatch: 5, nothingAdded: 5, fluency: 5)
        #expect(check(Evaluation.evaluate(correct, state: .ready(text: "The report is done.", flags: []), scope: .rewrite, judge: judged), "change")?.passed == false)
    }

    @Test("network failures, rate limits and cancellations are infrastructure failures, not quality ones")
    func infrastructure() {
        for state in [GenerationState.failed(.network, partial: ""), .failed(.rateLimited(retryAfter: nil), partial: ""), .cancelled] {
            let report = Evaluation.evaluate(benchCase(), state: state, scope: .rewrite)
            #expect(report.infrastructureFailure != nil, "\(state)")
            #expect(report.checks.isEmpty)
            #expect(!report.hardChecksPassed)
        }
    }

    @Test("similarity takes the closest reference")
    func closestReference() {
        let report = Evaluation.evaluate(benchCase(references: ["Something else entirely.", "The report is done now."]),
                                         state: .ready(text: "The report is done.", flags: []), scope: .rewrite)
        #expect(abs((report.referenceSimilarity ?? 0) - 0.8) < 1e-12)
    }

    @Test("criticality follows the categories")
    func critical() {
        #expect(Set(BenchCategory.allCases.filter(\.isCritical)) == [.alreadyCorrect, .whoDidWhat, .injection, .noAddedFormulas])
    }
}
