import CryptoKit
import Foundation
import Testing

@testable import QuillBench
@testable import RewriteKit

/// The bench's case set and gate files (BENCH §1.1, §2). Failures print case **ids
/// only**, never case text: holdout contents must not reach the tuning context.
@Suite("Bench case set")
struct CaseSetTests {
    // MARK: Loading

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()                               // CaseSetTests.swift → QuillBenchTests
        .deletingLastPathComponent().deletingLastPathComponent()   // → Tests → quill
        .deletingLastPathComponent().deletingLastPathComponent()   // → native → repository
    static let data = repository.appendingPathComponent("native/quill/tools/QuillBench/data", isDirectory: true)

    enum Split: String, CaseIterable { case dev, holdout }

    struct Loaded {
        var cases: [(split: Split, benchCase: BenchCase)] = []
        var problems: [String] = []
    }

    static let loaded: Loaded = {
        var result = Loaded()
        for split in Split.allCases {
            let folder = data.appendingPathComponent("cases/\(split.rawValue)", isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                do {
                    let cases = try JSONDecoder().decode([BenchCase].self, from: Data(contentsOf: file))
                    result.cases += cases.map { (split, $0) }
                } catch {
                    result.problems.append("\(split.rawValue)/\(file.lastPathComponent) does not decode")
                }
            }
        }
        return result
    }()

    static var active: [(split: Split, benchCase: BenchCase)] { loaded.cases.filter { !$0.benchCase.isRetired } }

    static func cases(_ profile: BuiltInProfile, _ split: Split? = nil) -> [BenchCase] {
        active.filter { $0.benchCase.profile == profile && (split == nil || $0.split == split) }.map(\.benchCase)
    }

    /// Every example a case must stay clear of: the built-ins' shipped examples and
    /// PRODUCT §5's worked examples.
    static let knownExamples: [String] = {
        var texts: [String] = []
        for profile in BuiltInProfile.allCases {
            for pair in (try? BuiltInProfiles.shippedExamples(profile)) ?? [] { texts += [pair.input, pair.output] }
        }
        let product = (try? String(contentsOf: repository.appendingPathComponent("docs/initiatives/quill/PRODUCT.md"), encoding: .utf8)) ?? ""
        var inSection = false
        for line in product.components(separatedBy: "\n") {
            if line.hasPrefix("## 5.") { inSection = true; continue }
            if line.hasPrefix("## 6.") { break }
            guard inSection else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- es:") || trimmed.hasPrefix("- en:") || trimmed.hasPrefix("→") else { continue }
            var rest = Substring(trimmed)
            while let open = rest.firstIndex(of: "\"") {
                let after = rest.index(after: open)
                guard let close = rest[after...].firstIndex(of: "\"") else { break }
                texts.append(String(rest[after..<close]))
                rest = rest[rest.index(after: close)...]
            }
        }
        return texts
    }()

    // MARK: Schema and counts

    @Test("every case file decodes, ids are unique and follow <profile>-<split>-NNN")
    func schema() {
        #expect(FileManager.default.fileExists(atPath: Self.data.appendingPathComponent("gate-v1.json").path),
                "the data folder was not found at \(Self.data.path)")
        #expect(!Self.loaded.cases.isEmpty, "no cases loaded")
        #expect(Self.loaded.problems.isEmpty, "\(Self.loaded.problems)")
        let ids = Self.loaded.cases.map(\.benchCase.id)
        #expect(Set(ids).count == ids.count, "duplicate ids")
        for (split, benchCase) in Self.loaded.cases {
            let prefix = "\(benchCase.profile.rawValue)-\(split == .dev ? "dev" : "hold")-"
            #expect(benchCase.id.hasPrefix(prefix), "\(benchCase.id): expected prefix \(prefix)")
            #expect(["es", "en"].contains(benchCase.language), "\(benchCase.id): language")
            #expect(!benchCase.references.isEmpty, "\(benchCase.id): no reference")
            #expect(!benchCase.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(benchCase.id): empty input")
        }
    }

    @Test("24 cases per built-in: 16 development and 8 holdout", arguments: BuiltInProfile.allCases)
    func counts(_ profile: BuiltInProfile) {
        #expect(Self.cases(profile, .dev).count == 16, "\(profile.rawValue) dev")
        #expect(Self.cases(profile, .holdout).count == 8, "\(profile.rawValue) holdout")
    }

    @Test("every category has at least two cases per profile", arguments: BuiltInProfile.allCases)
    func categoryCoverage(_ profile: BuiltInProfile) {
        let cases = Self.cases(profile)
        for category in BenchCategory.allCases {
            let count = cases.filter { $0.categories.contains(category) }.count
            #expect(count >= 2, "\(profile.rawValue): \(category.rawValue) has \(count)")
        }
    }

    @Test("the holdout covers every critical category plus exampleBait and refusalBait", arguments: BuiltInProfile.allCases)
    func holdoutCoverage(_ profile: BuiltInProfile) {
        let holdout = Self.cases(profile, .holdout)
        let required = BenchCategory.allCases.filter(\.isCritical) + [.exampleBait, .refusalBait]
        for category in required {
            #expect(holdout.contains { $0.categories.contains(category) }, "\(profile.rawValue) holdout lacks \(category.rawValue)")
        }
    }

    // MARK: Per-case rules

    @Test("critical is true exactly when a category is critical")
    func criticalFlag() {
        for (_, benchCase) in Self.active {
            #expect(benchCase.critical == benchCase.categories.contains(where: \.isCritical), "\(benchCase.id): critical")
        }
    }

    @Test("every reference satisfies its case's mustKeep and mustNotContain")
    func referencesSatisfyAnchors() {
        for (_, benchCase) in Self.active {
            for (index, reference) in benchCase.references.enumerated() {
                let lowered = reference.lowercased()
                for anchor in benchCase.mustKeep where !lowered.contains(anchor.lowercased()) {
                    Issue.record("\(benchCase.id): reference \(index) misses a mustKeep anchor")
                }
                for forbidden in benchCase.mustNotContain where lowered.contains(forbidden.lowercased()) {
                    Issue.record("\(benchCase.id): reference \(index) contains a mustNotContain string")
                }
            }
        }
    }

    @Test("case inputs stay clear of shipped and PRODUCT §5 examples")
    func disjointFromExamples() throws {
        let abbreviations = try AbbreviationTable.load()
        #expect(Self.knownExamples.count >= 16, "PRODUCT §5 examples were not found")
        for (_, benchCase) in Self.active {
            for example in Self.knownExamples
            where Similarity.folded(benchCase.input, example, abbreviations: abbreviations) >= 0.8 {
                Issue.record("\(benchCase.id): input within 0.8 of a known example")
            }
        }
    }

    @Test("exampleBait cases carry their own example, in the [0.5, 0.8) band, clear of known examples")
    func exampleBait() throws {
        let abbreviations = try AbbreviationTable.load()
        for (_, benchCase) in Self.active {
            let isBait = benchCase.categories.contains(.exampleBait)
            guard isBait else {
                #expect(benchCase.injectExample == nil, "\(benchCase.id): injectExample on a non-bait case")
                continue
            }
            guard let injected = benchCase.injectExample else {
                Issue.record("\(benchCase.id): exampleBait without injectExample")
                continue
            }
            let similarity = Similarity.folded(benchCase.input, injected.input, abbreviations: abbreviations)
            #expect(similarity >= 0.5 && similarity < 0.8, "\(benchCase.id): bait similarity \(String(format: "%.2f", similarity)) outside [0.5, 0.8)")
            for example in Self.knownExamples
            where Similarity.folded(injected.input, example, abbreviations: abbreviations) >= 0.8 {
                Issue.record("\(benchCase.id): injected example within 0.8 of a known example")
            }
        }
    }

    @Test("alreadyCorrect cases expect no change; for rewrite profiles they have at least 20 words")
    func alreadyCorrect() {
        for (_, benchCase) in Self.active where benchCase.categories.contains(.alreadyCorrect) {
            #expect(!benchCase.expectChange, "\(benchCase.id): alreadyCorrect expects a change")
            if (try? BuiltInProfiles.make(benchCase.profile, language: "en"))?.settings.scope == .rewrite {
                #expect(TextNormalizer.words(benchCase.input).count >= 20, "\(benchCase.id): under 20 words")
            }
        }
    }

    @Test("english cases are in English; nearContextLimit cases fit the on-device context with the reserve")
    func languageAndLength() {
        for (_, benchCase) in Self.active {
            if benchCase.categories.contains(.english) { #expect(benchCase.language == "en", "\(benchCase.id): english") }
            if benchCase.categories.contains(.nearContextLimit) {
                let words = TextNormalizer.words(benchCase.input).count
                #expect((450...750).contains(words), "\(benchCase.id): \(words) words")
                // Instructions + examples (≈ 700 tokens) + input + the 1.3 × reserve.
                let tokens = Double(benchCase.input.count) / TokenEstimateForTests.charactersPerToken
                #expect(700 + tokens * 2.3 < 4_096, "\(benchCase.id): does not fit the on-device context")
            }
        }
    }

    // MARK: Gate files

    struct Gate: Decodable {
        struct Rubric: Decodable { let version: Int; let file: String; let sha256: String }
        let gateVersion: Int
        let minimumRepeats: Int
        let thresholds: [String: [String: Double]]
        let allowedJudges: [String]
        let maximumCountedRuns: Int
        let releaseRuns: Int
        let rubric: Rubric
    }

    static func gates() throws -> [Gate] {
        let files = try FileManager.default.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("gate-v") && $0.pathExtension == "json" }
        return try files.map { file in
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
            // Booleans become 1/0 so every threshold compares as a number.
            var normalized = object
            if let thresholds = object["thresholds"] as? [String: [String: Any]] {
                normalized["thresholds"] = thresholds.mapValues { $0.mapValues { value -> Double in
                    if let bool = value as? Bool { return bool ? 1 : 0 }
                    return (value as? NSNumber)?.doubleValue ?? .nan
                } }
            }
            return try JSONDecoder().decode(Gate.self, from: JSONSerialization.data(withJSONObject: normalized))
        }
    }

    @Test("every gate file has identical thresholds and repeats, a matching rubric hash and judges from two vendors")
    func gateFiles() throws {
        let gates = try Self.gates()
        #expect(!gates.isEmpty)
        guard let first = gates.first else { return }
        for gate in gates {
            #expect(gate.thresholds == first.thresholds, "gate-v\(gate.gateVersion): thresholds differ")
            #expect(gate.minimumRepeats == first.minimumRepeats && gate.minimumRepeats == 3)
            #expect(gate.maximumCountedRuns == 8 && gate.releaseRuns == 2)
            let rubric = try Data(contentsOf: Self.data.appendingPathComponent(gate.rubric.file))
            let hash = SHA256.hash(data: rubric).map { String(format: "%02x", $0) }.joined()
            #expect(hash == gate.rubric.sha256, "gate-v\(gate.gateVersion): rubric hash")
            let vendors = Set(gate.allowedJudges.compactMap { $0.split(separator: ":").last?.split(separator: "/").first })
            #expect(vendors.count >= 2, "judges from at least two vendors")
        }
    }

    // MARK: The holdout lock (BENCH §2.3)

    @Test("holdout.lock matches every holdout file and gate file")
    func lockMatches() {
        let paths = BenchPaths(data: Self.data, support: FileManager.default.temporaryDirectory)
        // Locked since its first commit (P1-T7b); changes need an owner-approved trailer.
        guard FileManager.default.fileExists(atPath: paths.holdoutLock.path) else {
            Issue.record("cases/holdout.lock is missing")
            return
        }
        let mismatches = HoldoutTools(paths: paths).lockMismatches()
        #expect(mismatches.isEmpty, "holdout.lock does not match: \(mismatches)")
    }

    // MARK: References against the guards (one-off: BENCH §2)

    /// Not part of verify.sh: run when cases are written and at lock creation with
    /// `QUILL_CHECK_REFERENCES=1` (`quill-bench check-references` from P1-T7b).
    static var referenceCheckEnabled: Bool { ProcessInfo.processInfo.environment["QUILL_CHECK_REFERENCES"] == "1" }

    @Test("every reference passes every guard with no flag and meets its change expectation",
          .enabled(if: referenceCheckEnabled))
    func referencesPassGuards() throws {
        let guards = try OutputGuards()
        for (_, benchCase) in Self.active {
            let profile = try BuiltInProfiles.make(benchCase.profile, language: benchCase.language)
            let examples = (benchCase.pinnedExample.map { [$0] } ?? []) + profile.examples
            for (index, reference) in benchCase.references.enumerated() {
                let outcome = guards.evaluate(input: benchCase.input, output: reference,
                                              context: .init(settings: profile.settings, examples: examples))
                let state: GenerationState
                switch outcome.verdict {
                case .result(let text, let flags):
                    if !flags.isEmpty {
                        Issue.record("\(benchCase.id): reference \(index) raises \(Set(flags.map(\.guardID)).sorted())")
                        continue
                    }
                    state = .ready(text: text, flags: [])
                case .noChanges: state = .noChanges
                case .empty: Issue.record("\(benchCase.id): reference \(index) is empty"); continue
                case .refused: Issue.record("\(benchCase.id): reference \(index) reads as a refusal"); continue
                }
                let change = Evaluation.changeExpectation(benchCase, state: state,
                                                          output: state == .noChanges ? benchCase.input : reference,
                                                          flags: [], scope: profile.settings.scope, judge: nil)
                if !change.passed { Issue.record("\(benchCase.id): reference \(index) fails the change expectation") }
            }
        }
    }
}

enum TokenEstimateForTests {
    static let charactersPerToken = 3.5
}
