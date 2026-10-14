import Foundation

/// Keeps voice labels stable across diarization passes made during a meeting.
///
/// Each pass clusters everything heard so far from scratch, and its cluster names
/// ("S1", "S2"…) mean nothing from one pass to the next. A name the user gave to
/// "Persona 2" must stay on the same voice, so every pass is matched to the previous
/// one by the time they share: the new cluster that covers most of what "speaker-2"
/// covered before is "speaker-2" now. Clusters that match nothing are new people,
/// numbered on from the highest label so far, in order of first appearance.
///
/// A voice can vanish for a pass — merged into another while there is little of it — and
/// come back. Measured on the meeting bench: five voices, four at minute 6, five again
/// at minute 8, and the returning one took a new number, so a name given to it at
/// minute 3 would have been lost. Voices that disappear are kept as they were last seen,
/// and every pass is matched against each voice's latest evidence — the turns it had in
/// the last pass where it existed — with an optimal assignment, not a greedy one: a
/// merged voice covers the returning one's time too, and greedily it would take its
/// number.
public struct SpeakerLabeler: Sendable {
    /// The last pass, with stable labels.
    public private(set) var turns: [SpeakerTurn] = []
    /// Every label seen, with its turns in the last pass where it existed.
    private var evidence: [String: [SpeakerTurn]] = [:]
    private var next = 1

    public init() {}

    /// Relabels a pass so it continues the previous one.
    public mutating func label(_ pass: [SpeakerTurn]) -> [SpeakerTurn] {
        let clusters = Self.firstAppearance(pass)
        let labels = evidence.keys.sorted()
        var mapping: [String: String] = [:]
        if !labels.isEmpty, !clusters.isEmpty {
            let size = max(clusters.count, labels.count)
            var shared = [[Double]](repeating: [Double](repeating: 0, count: size), count: size)
            for (c, cluster) in clusters.enumerated() {
                for (l, label) in labels.enumerated() {
                    for a in pass where a.speaker == cluster {
                        for b in evidence[label]! {
                            shared[c][l] += max(0, min(a.end, b.end) - max(a.start, b.start))
                        }
                    }
                }
            }
            let most = shared.flatMap { $0 }.max() ?? 0
            let assignment = Self.optimalAssignment(shared.map { $0.map { most - $0 } })
            for (c, l) in assignment.enumerated() where c < clusters.count && l < labels.count && shared[c][l] > 0 {
                mapping[clusters[c]] = labels[l]
            }
        }
        for cluster in clusters where mapping[cluster] == nil {
            mapping[cluster] = "speaker-\(next)"
            next += 1
        }
        let known = Set(evidence.keys).union(mapping.values)
        next = max(next, (known.compactMap { Int($0.split(separator: "-").last ?? "") }.max() ?? 0) + 1)
        turns = pass.map { SpeakerTurn(speaker: mapping[$0.speaker] ?? $0.speaker, start: $0.start, end: $0.end) }
        for label in Set(turns.map(\.speaker)) { evidence[label] = turns.filter { $0.speaker == label } }
        return turns
    }

    /// The voice speaking most during `start…end`, if any.
    public func speaker(from start: Double, to end: Double) -> String? {
        var seconds: [String: Double] = [:]
        for turn in turns {
            let overlap = max(0, min(end, turn.end) - max(start, turn.start))
            if overlap > 0 { seconds[turn.speaker, default: 0] += overlap }
        }
        return seconds.max { $0.value < $1.value }?.key
    }

    /// Minimum-cost assignment for a square matrix (Hungarian method): row i takes column
    /// result[i].
    static func optimalAssignment(_ cost: [[Double]]) -> [Int] {
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

    private static func firstAppearance(_ turns: [SpeakerTurn]) -> [String] {
        var seen: [String] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) where !seen.contains(turn.speaker) {
            seen.append(turn.speaker)
        }
        return seen
    }
}
