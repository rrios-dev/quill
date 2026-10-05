import Foundation

/// The picker's diff (⌘D): word-level, so a rewrite reads as edits to the sentence
/// rather than as character noise.
enum WordDiff {
    enum Kind: Equatable { case same, removed, added }

    struct Segment: Equatable {
        var text: String
        var kind: Kind
    }

    /// Tokens keep their trailing whitespace, so joining every segment of one side gives
    /// that side back exactly.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSpace = false
        for character in text {
            let space = character.isWhitespace
            if !space && inSpace {
                tokens.append(current)
                current = ""
            }
            current.append(character)
            inSpace = space
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func segments(from old: String, to new: String) -> [Segment] {
        let a = tokens(old)
        let b = tokens(new)
        // Compare words without their trailing space, so a moved line break is not a change.
        let keyA = a.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let keyB = b.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = keyA[i] == keyB[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var result: [Segment] = []
        func append(_ text: String, _ kind: Kind) {
            if let last = result.last, last.kind == kind {
                result[result.count - 1].text += text
            } else {
                result.append(Segment(text: text, kind: kind))
            }
        }
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if keyA[i] == keyB[j] {
                append(b[j], .same)
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                append(a[i], .removed)
                i += 1
            } else {
                append(b[j], .added)
                j += 1
            }
        }
        while i < a.count { append(a[i], .removed); i += 1 }
        while j < b.count { append(b[j], .added); j += 1 }
        return result
    }
}
