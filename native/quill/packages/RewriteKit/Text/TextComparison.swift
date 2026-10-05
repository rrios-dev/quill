import Foundation

/// Normalisation shared by the guards and the evaluation (ARCHITECTURE §4.6, BENCH §1).
public enum TextNormalizer {
    /// Words, lowercased, with punctuation removed — the bench's reference similarity.
    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "@" || $0 == "'" || $0 == "’") }
            .map { String($0).replacingOccurrences(of: "’", with: "'") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// Words with case and accents folded, apostrophes dropped ("don't" → "dont"), and
    /// chat abbreviations expanded with the shared table whatever the profile's setting
    /// — the guards' comparison form (G6, G9, G10, G13).
    public static func folded(_ text: String, abbreviations: AbbreviationTable?) -> [String] {
        let base = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
        return base
            .split { !($0.isLetter || $0.isNumber || $0 == "@") }
            .flatMap { token -> [String] in
                let word = String(token)
                guard let expansion = abbreviations?.expansion(of: word) else { return [word] }
                return expansion.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    .replacingOccurrences(of: "'", with: "")
                    .split { !($0.isLetter || $0.isNumber) }.map(String.init)
            }
    }

    /// The folded words joined by single spaces, for phrase matching.
    public static func foldedPhrase(_ text: String, abbreviations: AbbreviationTable?) -> String {
        folded(text, abbreviations: abbreviations).joined(separator: " ")
    }
}

/// Word-level similarity: 1 − (word edit distance ÷ the longer length). 1 for equal
/// texts, 0 for texts with nothing in common; two empty texts are equal.
public enum Similarity {
    public static func words(_ a: [String], _ b: [String]) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(editDistance(a, b)) / Double(longest)
    }

    /// The bench's reference similarity: lowercased words, punctuation removed.
    public static func reference(_ a: String, _ b: String) -> Double {
        words(TextNormalizer.words(a), TextNormalizer.words(b))
    }

    /// The guards' similarity, over folded and abbreviation-expanded words.
    public static func folded(_ a: String, _ b: String, abbreviations: AbbreviationTable?) -> Double {
        words(TextNormalizer.folded(a, abbreviations: abbreviations), TextNormalizer.folded(b, abbreviations: abbreviations))
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
