import Foundation
import ListenKit

/// A word or phrase the transcriber gets wrong, and how it is written (VOICES.md S3–S4).
///
/// Learnt from the user's corrections of a transcript, never typed in a form: each
/// correction keeps the words that changed. It belongs to whoever said it (J-04): the
/// user ("me"), or a person of the directory; the same correction for two people offers
/// to make it global.
public struct VocabularyEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Scope: Codable, Hashable, Sendable {
        case global
        case me
        case person(UUID)
    }

    public var id: UUID
    /// What the transcriber wrote, as it wrote it.
    public var heard: String
    /// What the user corrected it to.
    public var written: String
    public var scope: Scope
    /// Corrections that taught it: the same one made again counts here.
    public var uses: Int
    public var createdAt: Date

    public init(id: UUID = UUID(), heard: String, written: String, scope: Scope, uses: Int = 1, createdAt: Date = Date()) {
        self.id = id
        self.heard = heard
        self.written = written
        self.scope = scope
        self.uses = uses
        self.createdAt = createdAt
    }

    /// Two entries teach the same thing whatever their case and accents.
    func same(as heard: String, _ written: String) -> Bool {
        Vocabulary.fold(self.heard) == Vocabulary.fold(heard) && self.written == written
    }
}

public enum Vocabulary {
    /// Longest run of words one correction may replace: longer is a rewrite, not a word
    /// the transcriber does not know.
    public static let maximumWords = 4

    /// The word replacements between what was transcribed and what the user wrote:
    /// runs of changed words on both sides, up to `maximumWords`. Words only added or only
    /// removed are edits, not vocabulary, and are left out; so are changes of case or
    /// punctuation alone, and sentences where less than half the words survive.
    public static func replacements(from old: String, to new: String) -> [(heard: String, written: String)] {
        let a = words(old), b = words(new)
        let keysA = a.map(fold), keysB = b.map(fold)
        // Longest common subsequence of the folded words.
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = keysA[i] == keysB[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        // A sentence mostly rewritten says how the user would put it, not which words the
        // transcriber missed.
        guard Double(table[0][0]) >= Double(max(a.count, b.count)) * 0.5 else { return [] }
        var result: [(String, String)] = []
        var i = 0, j = 0
        var removed: [String] = [], added: [String] = []
        func flush() {
            if !removed.isEmpty, !added.isEmpty, removed.count <= maximumWords, added.count <= maximumWords {
                result.append((removed.joined(separator: " "), added.joined(separator: " ")))
            }
            removed = []
            added = []
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, keysA[i] == keysB[j] {
                flush()
                i += 1
                j += 1
            } else if j < b.count, i == a.count || table[i][j + 1] >= table[i + 1][j] {
                added.append(b[j])
                j += 1
            } else {
                removed.append(a[i])
                i += 1
            }
        }
        flush()
        return result
    }

    /// `text` with every entry's heard words written as the user writes them: whole
    /// words, ignoring case. Longer entries first, so "cuber netes" wins over
    /// "cuber".
    public static func apply(_ entries: [VocabularyEntry], to text: String) -> String {
        var result = text
        for entry in entries.sorted(by: { $0.heard.count > $1.heard.count }) {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: entry.heard) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range,
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: entry.written))
        }
        return result
    }

    /// The words of a sentence without the punctuation around them.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

extension MeetingRecord {
    /// Whose words a voice label holds, for the vocabulary: the user, the person it was
    /// named as, or nobody yet.
    public func vocabularyScope(of label: String) -> VocabularyEntry.Scope? {
        if label == "me" { return .me }
        return people[label].map { .person($0) }
    }
}
