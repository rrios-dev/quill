import Foundation

/// Splits one voice into two people, from voiceprints of its pieces.
///
/// The diarizer clusters on each voice's pieces and can merge two people who sound alike;
/// when the user says "these are two people", the pieces of that voice are split again
/// on their own, where the third, fourth… voices no longer pull the clustering.
public enum VoiceSplit {
    /// Two groups by cosine similarity (spherical 2-means): `result[i]` is 0 or 1.
    ///
    /// `known` pins pieces whose person the user said (index → group): they seed the
    /// groups and never move. Measured on the most alike pair of the bench (VOICES.md S1):
    /// blind, the split is barely better than chance; with a few pieces known it is not.
    /// Without anything known it is seeded with the two least alike pieces, so the same
    /// input always gives the same split. Fewer than two pieces are all group 0.
    public static func twoWay(_ prints: [[Float]], known: [Int: Int] = [:], iterations: Int = 20) -> [Int] {
        guard prints.count >= 2 else { return [Int](repeating: 0, count: prints.count) }
        let unit = prints.map(normalized)
        var groups: [Int]
        if Set(known.values) == [0, 1] {
            groups = unit.indices.map { known[$0] ?? 0 }
            let centres = centres(unit, groups: groups, only: Set(known.keys))
            // Nearest known centroid, no re-estimation: on alike voices the unmarked pieces
            // pull the centres back together (measured: 2-means from these seeds lost up to
            // 60 points on the second pair of the bench).
            return unit.indices.map { known[$0] ?? (dot(unit[$0], centres[0]) >= dot(unit[$0], centres[1]) ? 0 : 1) }
        } else {
            var seeds = (0, 1)
            var lowest = Float.infinity
            for i in unit.indices {
                for j in unit.indices where j > i {
                    let similarity = dot(unit[i], unit[j])
                    if similarity < lowest { lowest = similarity; seeds = (i, j) }
                }
            }
            groups = unit.map { dot($0, unit[seeds.0]) >= dot($0, unit[seeds.1]) ? 0 : 1 }
        }
        for _ in 0..<iterations {
            let centres = centres(unit, groups: groups, only: nil)
            let next = unit.indices.map { known[$0] ?? (dot(unit[$0], centres[0]) >= dot(unit[$0], centres[1]) ? 0 : 1) }
            if next == groups { break }
            groups = next
        }
        return groups
    }

    /// "This sentence is someone else": the `marked` pieces are the second person, and
    /// every other piece goes with whichever side it is closer to — the marked pieces'
    /// centre, or the centre of the rest. One pass of reassignment, then the rest's centre
    /// is taken again without the pieces that left. `result[i]` is 1 for the second person.
    public static func peelingOff(_ prints: [[Float]], marked: Set<Int>) -> [Int] {
        guard !marked.isEmpty, marked.count < prints.count else { return prints.indices.map { marked.contains($0) ? 1 : 0 } }
        let unit = prints.map(normalized)
        var groups = unit.indices.map { marked.contains($0) ? 1 : 0 }
        for _ in 0..<2 {
            let rest = centres(unit, groups: groups, only: nil)[0]
            let peeled = centres(unit, groups: groups, only: marked)[1]
            groups = unit.indices.map {
                marked.contains($0) ? 1 : (dot(unit[$0], rest) >= dot(unit[$0], peeled) ? 0 : 1)
            }
        }
        return groups
    }

    /// Each group's mean direction, from all pieces or only `only`.
    static func centres(_ unit: [[Float]], groups: [Int], only: Set<Int>?) -> [[Float]] {
        (0..<2).map { group in
            let members = unit.indices.filter { groups[$0] == group && (only?.contains($0) ?? true) }.map { unit[$0] }
            guard let first = members.first else { return [Float](repeating: 0, count: unit[0].count) }
            return normalized(members.dropFirst().reduce(first) { zip($0, $1).map(+) })
        }
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : vector
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
