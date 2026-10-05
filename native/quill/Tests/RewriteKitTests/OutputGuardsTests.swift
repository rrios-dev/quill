import Foundation
import Testing

@testable import RewriteKit

/// A table test per guard, from `Fixtures/guard-cases.json` — the measured failures
/// and the false-positive traps of PLAN P1-T3. Spanish case text lives in the JSON.
@Suite("Output guards")
struct OutputGuardsTests {
    struct Case: Decodable, CustomTestStringConvertible, Sendable {
        let id: String
        let profile: BuiltInProfile
        let input: String
        let output: String
        let verdict: String
        let text: String?
        let include: [String]?
        let exclude: [String]?
        let examples: String?
        let formatting: CaptureFormatting?
        let target: String?
        let stripped: Bool?
        var testDescription: String { id }
    }

    struct File: Decodable { let cases: [Case] }

    static let cases: [Case] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/guard-cases.json")
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else {
            return []
        }
        return file.cases
    }()

    @Test("the case table loads and covers every guard")
    func coverage() {
        #expect(Self.cases.count >= 50)
        let covered = Set(Self.cases.flatMap { ($0.include ?? []) + ($0.exclude ?? []) })
            .union(Self.cases.compactMap { ["noChanges": "G7", "empty": "G8", "refused": "G10"][$0.verdict] })
        for guardID in (1...13).map({ "G\($0)" }) {
            #expect(covered.contains(guardID), "\(guardID) has no case")
        }
    }

    @Test("guard case", arguments: cases)
    func guardCase(_ testCase: Case) throws {
        let guards = try OutputGuards()
        var settings = try BuiltInProfiles.make(testCase.profile, language: "es").settings
        if let target = testCase.target { settings.targetLanguage = target; settings.scope = .rewrite }
        let examples = testCase.examples == "builtin" ? try BuiltInProfiles.make(testCase.profile, language: "es").examples : []
        let outcome = guards.evaluate(
            input: testCase.input, output: testCase.output,
            context: .init(settings: settings, examples: examples, formatting: testCase.formatting ?? .plain))

        switch (testCase.verdict, outcome.verdict) {
        case ("result", .result(let text, let flags)):
            let ids = Set(flags.map(\.guardID))
            for id in testCase.include ?? [] { #expect(ids.contains(id), "\(testCase.id): expected \(id), got \(flags)") }
            for id in testCase.exclude ?? [] { #expect(!ids.contains(id), "\(testCase.id): unexpected \(id) in \(flags)") }
            if let expected = testCase.text { #expect(text == expected, "\(testCase.id): text") }
        case ("noChanges", .noChanges), ("empty", .empty), ("refused", .refused):
            break
        default:
            Issue.record("\(testCase.id): expected \(testCase.verdict), got \(outcome.verdict)")
        }
        if let stripped = testCase.stripped { #expect((outcome.stripped != nil) == stripped, "\(testCase.id): stripped") }
    }

    @Test("similarity is 1 for equal texts, 0 for disjoint ones, and ignores case and punctuation")
    func similarity() {
        #expect(Similarity.reference("Hello, world!", "hello world") == 1)
        #expect(Similarity.reference("one two", "three four") == 0)
        #expect(abs(Similarity.reference("a b c d", "a b x d") - 0.75) < 1e-9)
        #expect(Similarity.reference("", "") == 1)
    }

    @Test("numbers are read with the language's separators")
    func numberValues() {
        #expect(Facts.value(of: "1.000", languageCode: "es") == 1000)
        #expect(Facts.value(of: "1,5", languageCode: "es") == Decimal(string: "1.5"))
        #expect(Facts.value(of: "1,000", languageCode: "en") == 1000)
        #expect(Facts.value(of: "1.5", languageCode: "en") == Decimal(string: "1.5"))
        #expect(Facts.value(of: "2,5", languageCode: "es") != Facts.value(of: "25", languageCode: "es"))
    }
}
