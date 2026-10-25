import Foundation

/// The user correcting who said what: a sentence that went to the wrong voice moves to
/// another one, and the sentences that sound like it are proposed to follow.
///
/// Segments are addressed by their index in `segments`, which these operations never
/// reorder.
extension Transcript {
    /// The next free voice label ("speaker-5" after "speaker-4"), for a person the
    /// diarizer did not hear as their own.
    public var newVoiceLabel: String {
        let numbers = segments.compactMap { $0.speaker?.split(separator: "-").last.flatMap { Int($0) } }
            + names.keys.compactMap { $0.split(separator: "-").last.flatMap { Int($0) } }
        return "speaker-\((numbers.max() ?? 0) + 1)"
    }

    /// Gives `indices` to `label`. Only the others' segments move: `me` comes from the
    /// microphone and is exact.
    public mutating func move(_ indices: some Sequence<Int>, to label: String) {
        for index in indices where segments.indices.contains(index) && segments[index].channel == .others {
            segments[index].speaker = label
        }
    }

    /// The segments still under `source` that sound like `target`'s, to propose moving
    /// them too. Measured on the bench (VOICES.md S1): one sentence of the other person
    /// is not enough to tell two alike voices apart, two or three are — so nothing is
    /// proposed until `target` holds at least `minimumMarks` measured sentences.
    public func soundingLike(_ target: String, from source: String, minimumMarks: Int = 2) -> [Int] {
        let marked = segments.indices.filter { segments[$0].speaker == target && segments[$0].voiceprint != nil }
        let candidates = segments.indices.filter { segments[$0].speaker == source && segments[$0].voiceprint != nil }
        guard marked.count >= minimumMarks, !candidates.isEmpty else { return [] }
        let pieces = marked + candidates
        let groups = VoiceSplit.peelingOff(pieces.map { segments[$0].voiceprint!.values }, marked: Set(marked.indices))
        return candidates.indices.filter { groups[marked.count + $0] == 1 }.map { candidates[$0] }
    }
}
