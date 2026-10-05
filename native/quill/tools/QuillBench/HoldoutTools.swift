import Foundation
import RewriteKit

/// The holdout's maintenance (BENCH §2, §2.3). Nothing here prints case text: every
/// command reports ids only.
struct HoldoutTools: Sendable {
    let paths: BenchPaths

    enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case unknownCase(String)
        case badID(String)
        case duplicateID(String)
        case unreadable(String)

        var description: String {
            switch self {
            case .unknownCase(let id): "no holdout case \(id)"
            case .badID(let id): "\(id) is not a holdout id (<profile>-hold-NNN)"
            case .duplicateID(let id): "\(id) already exists"
            case .unreadable(let file): "\(file) does not decode"
            }
        }
    }

    // MARK: Lock

    /// The lock's lines: `<sha256>  <path relative to the data folder>`, for every holdout
    /// file and every gate file, sorted — `shasum -a 256` format.
    func lockContents() throws -> String {
        let fileManager = FileManager.default
        var lines: [String] = []
        let holdout = try fileManager.contentsOfDirectory(at: paths.holdoutCases, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        for file in holdout {
            lines.append("\(HoldoutLock.sha256(try Data(contentsOf: file)))  cases/holdout/\(file.lastPathComponent)")
        }
        let gates = try fileManager.contentsOfDirectory(at: paths.data, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("gate-v") && $0.pathExtension == "json" }
        for file in gates {
            lines.append("\(HoldoutLock.sha256(try Data(contentsOf: file)))  \(file.lastPathComponent)")
        }
        return lines.sorted { $0.split(separator: " ").last! < $1.split(separator: " ").last! }.joined(separator: "\n") + "\n"
    }

    func writeLock() throws {
        try lockContents().write(to: paths.holdoutLock, atomically: true, encoding: .utf8)
    }

    /// Lock lines that no longer match their files (empty when the lock is intact).
    func lockMismatches() -> [String] {
        guard let lock = try? String(contentsOf: paths.holdoutLock, encoding: .utf8),
              let current = try? lockContents() else { return ["lock unreadable"] }
        let expected = Set(lock.split(separator: "\n").map(String.init))
        let actual = Set(current.split(separator: "\n").map(String.init))
        // A changed file differs in two lines (its old and new hash): report its path once.
        return Set(expected.symmetricDifference(actual).compactMap { $0.split(separator: " ").last.map(String.init) }).sorted()
    }

    // MARK: Cases

    func file(for profile: BuiltInProfile) -> URL {
        paths.holdoutCases.appendingPathComponent("\(profile.rawValue).json")
    }

    func cases(_ profile: BuiltInProfile) throws -> [BenchCase] {
        let url = file(for: profile)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do { return try JSONDecoder().decode([BenchCase].self, from: Data(contentsOf: url)) } catch {
            throw Failure.unreadable(url.lastPathComponent)
        }
    }

    func save(_ cases: [BenchCase], for profile: BuiltInProfile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(cases.sorted { $0.id < $1.id }).write(to: file(for: profile), options: .atomic)
    }

    /// `holdout add --from <file>`: appends new holdout cases and regenerates the lock.
    /// Owner-initiated; the commit carries the `Holdout-Change:` trailer (BENCH §2.3).
    @discardableResult
    func add(from source: URL) throws -> [String] {
        let new: [BenchCase]
        do { new = try JSONDecoder().decode([BenchCase].self, from: Data(contentsOf: source)) } catch {
            throw Failure.unreadable(source.lastPathComponent)
        }
        var added: [String] = []
        for profile in BuiltInProfile.allCases {
            let incoming = new.filter { $0.profile == profile }
            guard !incoming.isEmpty else { continue }
            var existing = try cases(profile)
            for benchCase in incoming {
                guard benchCase.id.hasPrefix("\(profile.rawValue)-hold-") else { throw Failure.badID(benchCase.id) }
                guard !existing.contains(where: { $0.id == benchCase.id }) else { throw Failure.duplicateID(benchCase.id) }
                existing.append(benchCase)
                added.append(benchCase.id)
            }
            try save(existing, for: profile)
        }
        try writeLock()
        return added
    }

    /// `holdout retire <id> --reason …`: marks the case retired, keeps it, regenerates the lock.
    func retire(_ id: String, reason: String) throws {
        guard let profile = BuiltInProfile.allCases.first(where: { id.hasPrefix("\($0.rawValue)-hold-") }) else {
            throw Failure.badID(id)
        }
        var existing = try cases(profile)
        guard let index = existing.firstIndex(where: { $0.id == id }) else { throw Failure.unknownCase(id) }
        existing[index].retired = true
        existing[index].retiredReason = reason
        try save(existing, for: profile)
        try writeLock()
    }

    // MARK: References

    struct Parked: Codable, Sendable {
        var evaluationVersion: Int
        var ids: [String]
    }

    var parkedURL: URL { paths.sealed.appendingPathComponent("parked.json") }

    /// `check-references`: re-checks every holdout reference against the guards (with the
    /// shipped plus injected examples) and parks the failing cases for the owner. Returns
    /// the parked ids.
    @discardableResult
    func checkReferences() throws -> [String] {
        let guards = try OutputGuards()
        var failing: [String] = []
        for profile in BuiltInProfile.allCases {
            let builtIn = try BuiltInProfiles.make(profile, language: "es")
            for benchCase in try cases(profile) where !benchCase.isRetired {
                let examples = (benchCase.pinnedExample.map { [$0] } ?? []) + builtIn.examples
                let passes = benchCase.references.allSatisfy { reference in
                    let outcome = guards.evaluate(input: benchCase.input, output: reference,
                                                  context: .init(settings: builtIn.settings, examples: examples))
                    let state: GenerationState
                    switch outcome.verdict {
                    case .result(let text, let flags):
                        guard flags.isEmpty else { return false }
                        state = .ready(text: text, flags: [])
                    case .noChanges: state = .noChanges
                    case .empty, .refused: return false
                    }
                    return Evaluation.changeExpectation(
                        benchCase, state: state, output: state == .noChanges ? benchCase.input : reference,
                        flags: [], scope: builtIn.settings.scope, judge: nil).passed
                }
                if !passes { failing.append(benchCase.id) }
            }
        }
        try writeParked(Parked(evaluationVersion: RewriteKitVersion.evaluation, ids: failing))
        return failing
    }

    func writeParked(_ parked: Parked) throws {
        try FileManager.default.createDirectory(at: paths.sealed, withIntermediateDirectories: true)
        try JSONEncoder().encode(parked).write(to: parkedURL, options: .atomic)
    }

    /// The parked ids, re-checking first when RewriteKit's evaluation version changed —
    /// a guard fix never turns a run red over cases the agent may not read.
    func ensureReferencesChecked() -> Set<String> {
        if let data = try? Data(contentsOf: parkedURL), let parked = try? JSONDecoder().decode(Parked.self, from: data),
           parked.evaluationVersion == RewriteKitVersion.evaluation {
            return Set(parked.ids)
        }
        return Set((try? checkReferences()) ?? [])
    }

    // MARK: Sealed failures

    /// Per-case failures of a gate run, outside the repository, for the owner to judge
    /// (BENCH §2.2). The tuning agent never opens this folder.
    func writeSealed(_ runs: [CaseRun], label: String) throws {
        try FileManager.default.createDirectory(at: paths.sealed, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(runs).write(to: paths.sealed.appendingPathComponent("\(label).json"), options: .atomic)
    }
}
