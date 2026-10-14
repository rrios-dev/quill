import Foundation

/// The numbers the meeting bench reports, each against a reference that says exactly who
/// said what and when. Standard definitions, so they compare with published results:
/// WER as edit distance over reference words, DER as NIST's frame-level error with an
/// optimal one-to-one speaker mapping and no collar.
enum Metrics {
    // MARK: Words

    /// Lowercase, accents folded, punctuation dropped: "¿Está?" and "esta" are one word.
    /// What it does not forgive is the model's own choices, like "10" for "diez".
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    enum Edit: Equatable { case match(Int, Int), substitution(Int, Int), deletion(Int), insertion(Int) }

    /// The minimum-cost alignment of `hypothesis` to `reference`, as a list of edits.
    static func align(_ reference: [String], _ hypothesis: [String]) -> [Edit] {
        let n = reference.count, m = hypothesis.count
        var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let same = reference[i - 1] == hypothesis[j - 1]
                    cost[i][j] = min(cost[i - 1][j - 1] + (same ? 0 : 1), cost[i - 1][j] + 1, cost[i][j - 1] + 1)
                }
            }
        }
        var edits: [Edit] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1) {
                edits.append(reference[i - 1] == hypothesis[j - 1] ? .match(i - 1, j - 1) : .substitution(i - 1, j - 1))
                i -= 1
                j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                edits.append(.deletion(i - 1))
                i -= 1
            } else {
                edits.append(.insertion(j - 1))
                j -= 1
            }
        }
        return edits.reversed()
    }

    /// Word error rate: (substitutions + deletions + insertions) / reference words.
    static func wer(_ edits: [Edit], referenceCount: Int) -> Double {
        guard referenceCount > 0 else { return 0 }
        let errors = edits.filter { if case .match = $0 { false } else { true } }.count
        return Double(errors) / Double(referenceCount)
    }

    // MARK: Speakers

    struct Turn: Equatable, Codable {
        var speaker: String
        var start: Double
        var end: Double
    }

    /// The one-to-one mapping from hypothesis speakers to reference speakers that
    /// maximises the time they share (Hungarian method). Speakers left over stay unmapped.
    static func mapping(reference: [Turn], hypothesis: [Turn]) -> [String: String] {
        let refSpeakers = Array(Set(reference.map(\.speaker))).sorted()
        let hypSpeakers = Array(Set(hypothesis.map(\.speaker))).sorted()
        guard !refSpeakers.isEmpty, !hypSpeakers.isEmpty else { return [:] }
        let size = max(refSpeakers.count, hypSpeakers.count)
        var overlap = [[Double]](repeating: [Double](repeating: 0, count: size), count: size)
        for (h, hypSpeaker) in hypSpeakers.enumerated() {
            for (r, refSpeaker) in refSpeakers.enumerated() {
                var shared = 0.0
                for a in hypothesis where a.speaker == hypSpeaker {
                    for b in reference where b.speaker == refSpeaker {
                        shared += max(0, min(a.end, b.end) - max(a.start, b.start))
                    }
                }
                overlap[h][r] = shared
            }
        }
        let maxValue = overlap.flatMap { $0 }.max() ?? 0
        let assignment = hungarian(overlap.map { $0.map { maxValue - $0 } })
        var result: [String: String] = [:]
        for (h, r) in assignment.enumerated() where h < hypSpeakers.count && r < refSpeakers.count && overlap[h][r] > 0 {
            result[hypSpeakers[h]] = refSpeakers[r]
        }
        return result
    }

    struct Diarization: Codable, Equatable {
        var der: Double
        var missed: Double
        var falseAlarm: Double
        var confusion: Double
        var referenceSpeakers: Int
        var hypothesisSpeakers: Int
    }

    /// NIST diarization error rate on 10 ms frames, no collar, overlap scored.
    static func diarization(reference: [Turn], hypothesis: [Turn], mapping: [String: String]) -> Diarization {
        let step = 0.01
        let end = max(reference.map(\.end).max() ?? 0, hypothesis.map(\.end).max() ?? 0)
        let frames = Int((end / step).rounded(.up))
        func active(_ turns: [Turn]) -> [Set<String>] {
            var sets = [Set<String>](repeating: [], count: frames + 1)
            for turn in turns {
                let first = max(0, Int((turn.start / step).rounded()))
                let last = min(frames, Int((turn.end / step).rounded()))
                if first < last { for frame in first..<last { sets[frame].insert(turn.speaker) } }
            }
            return sets
        }
        let ref = active(reference), hyp = active(hypothesis)
        var total = 0, missed = 0, falseAlarm = 0, confusion = 0
        for frame in 0...frames {
            let r = ref[frame], h = Set(hyp[frame].compactMap { mapping[$0] ?? "unmapped:\($0)" })
            let correct = r.intersection(h).count
            total += r.count
            missed += max(0, r.count - h.count)
            falseAlarm += max(0, h.count - r.count)
            confusion += min(r.count, h.count) - correct
        }
        let denominator = Double(max(total, 1))
        return Diarization(
            der: Double(missed + falseAlarm + confusion) / denominator,
            missed: Double(missed) / denominator,
            falseAlarm: Double(falseAlarm) / denominator,
            confusion: Double(confusion) / denominator,
            referenceSpeakers: Set(reference.map(\.speaker)).count,
            hypothesisSpeakers: Set(hypothesis.map(\.speaker)).count
        )
    }

    /// Minimum-cost assignment for a square cost matrix: row i takes column result[i].
    static func hungarian(_ cost: [[Double]]) -> [Int] {
        let n = cost.count
        guard n > 0 else { return [] }
        var u = [Double](repeating: 0, count: n + 1), v = [Double](repeating: 0, count: n + 1)
        var p = [Int](repeating: 0, count: n + 1), way = [Int](repeating: 0, count: n + 1)
        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = [Double](repeating: .infinity, count: n + 1)
            var used = [Bool](repeating: false, count: n + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.infinity, j1 = 0
                for j in 1...n where !used[j] {
                    let current = cost[i0 - 1][j - 1] - u[i0] - v[j]
                    if current < minv[j] { minv[j] = current; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...n {
                    if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta }
                }
                j0 = j1
            } while p[j0] != 0
            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }
        var result = [Int](repeating: 0, count: n)
        for j in 1...n where p[j] > 0 { result[p[j] - 1] = j - 1 }
        return result
    }
}
