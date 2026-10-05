import Foundation
import RewriteKit

/// `baseline` and `export-readiness` (BENCH §3, ARCHITECTURE §5.1).
struct ReadinessTools: Sendable {
    let paths: BenchPaths

    enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case noSuchRun(String)
        case personalCases(String)

        var description: String {
            switch self {
            case .noSuchRun(let label): "no result labelled \(label) in \(label.isEmpty ? "" : "the results folder")"
            case .personalCases(let label): "refused: \(label) used personal cases, which never enter the repository"
            }
        }
    }

    /// The newest result file labelled `label`.
    func resultFile(labelled label: String) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.results, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix("-\(label).json") }.max { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Copies a run into `tools/QuillBench/data/baselines/`, refusing one that used any
    /// personal case, so personal text cannot be committed by accident.
    @discardableResult
    func baseline(_ label: String) throws -> URL {
        guard let source = resultFile(labelled: label) else { throw Failure.noSuchRun(label) }
        let data = try Data(contentsOf: source)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let report = try? decoder.decode(RunReport.self, from: data), report.runs.contains(where: \.personal) {
            throw Failure.personalCases(label)
        }
        try FileManager.default.createDirectory(at: paths.baselines, withIntermediateDirectories: true)
        let destination = paths.baselines.appendingPathComponent("\(label).json")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    struct Entry: Codable, Equatable, Sendable {
        var promptHash: String
        /// Canonical model identity (ARCHITECTURE §5.1).
        var model: String
        var evaluationVersion: Int
        /// BENCH's verdict: "ready (confirmed)", "not ready (development 42 %)", …
        var verdict: String
        /// The app's label: "works well", "may need review", "not recommended", "not evaluated".
        var label: String
    }

    struct File: Codable, Sendable {
        var schemaVersion = 1
        var entries: [Entry]
    }

    /// BENCH's verdicts mapped to the app's labels (ARCHITECTURE §5.1).
    static func label(for verdict: String) -> String {
        if verdict == "ready (confirmed)" { return "works well" }
        if verdict == "ready (unconfirmed)" { return "may need review" }
        if verdict.hasPrefix("not ready") { return "not recommended" }
        return "not evaluated"
    }

    /// Regenerates `readiness.json` from the committed gate log and development baselines,
    /// keyed by prompt hash × canonical model identity × evaluation version. A gate
    /// verdict wins over a development one for the same key; the newest gate verdict wins.
    func exportReadiness() throws -> File {
        var byKey: [String: Entry] = [:]
        func key(_ hash: String, _ model: String, _ version: Int) -> String { "\(hash)|\(model)|\(version)" }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.baselines, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.lastPathComponent != "gate-log.json" {
            guard let report = try? decoder.decode(RunReport.self, from: Data(contentsOf: file)), report.command == "run" else { continue }
            for summary in report.summaries {
                guard let hash = summary.promptHash else { continue }
                let scope = (try? BuiltInProfiles.make(summary.profile, language: "es"))?.settings.scope ?? .rewrite
                let verdict: String
                if summary.developmentVerdict.hasPrefix("not ready") {
                    verdict = summary.developmentVerdict
                } else if scope == .rewrite, report.judge == nil {
                    verdict = "not evaluated (no judge)"
                } else {
                    verdict = "not evaluated (no gate run)"
                }
                let entry = Entry(promptHash: hash, model: summary.identity ?? summary.model.canonicalIdentity,
                                  evaluationVersion: report.evaluationVersion, verdict: verdict, label: Self.label(for: verdict))
                byKey[key(hash, entry.model, entry.evaluationVersion)] = entry
            }
        }
        for gateEntry in GateLog.load(paths.baselines.appendingPathComponent("gate-log.json")).entries where gateEntry.counted {
            let entry = Entry(promptHash: gateEntry.promptHash, model: gateEntry.identity,
                              evaluationVersion: gateEntry.evaluationVersion, verdict: gateEntry.verdict,
                              label: Self.label(for: gateEntry.verdict))
            byKey[key(entry.promptHash, entry.model, entry.evaluationVersion)] = entry
        }
        let file = File(entries: byKey.values.sorted { ($0.model, $0.promptHash) < ($1.model, $1.promptHash) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(file).write(to: paths.data.appendingPathComponent("readiness.json"), options: .atomic)
        return file
    }
}
