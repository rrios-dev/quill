import Testing

@testable import ListenKit

/// Splitting one voice into two people, on voiceprints small enough to reason about:
/// two directions in the plane with noise around each.
@Suite("Voice split")
struct VoiceSplitTests {
    /// Pieces of person A lean towards (1, 0), of person B towards (0.8, 0.6): alike voices.
    static let a: [[Float]] = [[1, 0.05], [0.98, 0.12], [1, -0.02], [0.97, 0.15]]
    static let b: [[Float]] = [[0.8, 0.6], [0.75, 0.62], [0.82, 0.55], [0.7, 0.7]]

    @Test("blind, the two least alike pieces seed the groups and each piece joins the closer one")
    func blind() {
        let groups = VoiceSplit.twoWay(Self.a + Self.b)
        #expect(Set(groups[0..<4]).count == 1)
        #expect(Set(groups[4..<8]).count == 1)
        #expect(groups[0] != groups[4])
    }

    @Test("known pieces keep their person and decide the rest")
    func known() {
        let groups = VoiceSplit.twoWay(Self.a + Self.b, known: [0: 1, 4: 0])
        #expect(groups == [1, 1, 1, 1, 0, 0, 0, 0])
    }

    @Test("marking sentences of the other person peels the pieces like them off the voice")
    func peelingOff() {
        let groups = VoiceSplit.peelingOff(Self.a + Self.b, marked: [5, 6])
        #expect(groups == [0, 0, 0, 0, 1, 1, 1, 1])
    }

    @Test("nothing marked, or everything, leaves the voice as it was said")
    func degenerate() {
        #expect(VoiceSplit.peelingOff(Self.a, marked: []) == [0, 0, 0, 0])
        #expect(VoiceSplit.peelingOff(Self.a, marked: [0, 1, 2, 3]) == [1, 1, 1, 1])
        #expect(VoiceSplit.twoWay([[1, 0]]) == [0])
    }
}
