import Foundation
import NaturalLanguage

/// What a text asserts that a rewrite must keep (G3) and must not invent (G12):
/// numbers by value, absolute dates and times, links, @mentions, e-mail addresses,
/// emoji and names (ARCHITECTURE §4.6).
struct Facts {
    var numbers: [Decimal] = []
    /// Absolute dates and times as their components, so "15/10" = "15 de octubre" and
    /// "3pm" = "15:00".
    var dates: [DateKey] = []
    var links: Set<String> = []
    var mentions: Set<String> = []
    var emails: Set<String> = []
    var emoji: Set<Character> = []
    /// Raw text of each absolute date, for reporting.
    var dateTexts: [DateKey: String] = [:]
    var numberTexts: [Decimal: String] = [:]

    struct DateKey: Hashable {
        var month: Int?
        var day: Int?
        var hour: Int?
        var minute: Int?
    }

    /// `languageCode` picks the decimal and thousands separators: es "1.000" and "1,5",
    /// en "1,000" and "1.5".
    static func extract(from text: String, languageCode: String?, months: Set<String>) -> Facts {
        var facts = Facts()
        var claimed: [Range<String.Index>] = []
        let whole = NSRange(text.startIndex..., in: text)

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue
                                                     | NSTextCheckingResult.CheckingType.date.rawValue) {
            for match in detector.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text) else { continue }
                let matched = String(text[range])
                switch match.resultType {
                case .link:
                    claimed.append(range)
                    if match.url?.scheme == "mailto" {
                        facts.emails.insert(matched.lowercased())
                    } else {
                        facts.links.insert(matched.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:")))
                    }
                case .date:
                    // Relative words ("mañana", "tomorrow", weekdays) are not dates here:
                    // only matches with a digit or a month name are absolute.
                    let folded = matched.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    let hasMonth = folded.split { !$0.isLetter }.contains { months.contains(String($0)) }
                    guard matched.contains(where: \.isNumber) || hasMonth, let date = match.date else { continue }
                    claimed.append(range)
                    let calendar = Calendar(identifier: .gregorian)
                    let components = calendar.dateComponents(in: match.timeZone ?? .current, from: date)
                    let hasTime = matched.contains(":") || folded.range(of: #"\d\s*(am|pm|h)\b"#, options: .regularExpression) != nil
                        || folded.contains("a las ") || folded.contains(" at ")
                    let hasDay = hasMonth || matched.range(of: #"\d{1,2}[/.\-]\d{1,2}"#, options: .regularExpression) != nil
                    let key = DateKey(
                        month: hasDay ? components.month : nil, day: hasDay ? components.day : nil,
                        hour: hasTime ? components.hour : nil, minute: hasTime ? components.minute : nil)
                    facts.dates.append(key)
                    facts.dateTexts[key] = matched
                default:
                    continue
                }
            }
        }

        for mention in Self.matches(#"(?<![\w@.])@[A-Za-z0-9_][A-Za-z0-9_.]*[A-Za-z0-9_]"#, in: text) {
            facts.mentions.insert(String(text[mention]).lowercased())
            claimed.append(mention)
        }

        // A number stands on its own: digits inside a word ("b4", "salu2", "gr8") are part of
        // a chat abbreviation, not a quantity.
        for number in Self.matches(#"(?<![\p{L}\d])\d+(?:[.,]\d+)*(?![\p{L}\d])"#, in: text)
        where !claimed.contains(where: { $0.overlaps(number) }) {
            let raw = String(text[number])
            if let value = Self.value(of: raw, languageCode: languageCode) {
                facts.numbers.append(value)
                facts.numberTexts[value] = raw
            }
        }

        for character in text where Self.isEmoji(character) { facts.emoji.insert(character) }
        return facts
    }

    /// The value of a number as written, with the language's separators.
    static func value(of raw: String, languageCode: String?) -> Decimal? {
        let decimalComma = !(languageCode?.hasPrefix("en") ?? false)
        let thousands: Character = decimalComma ? "." : ","
        let decimal: Character = decimalComma ? "," : "."
        var text = raw
        // A separator followed by exactly three digits in a grouping pattern is thousands.
        let groupPattern = decimalComma ? #"^\d{1,3}(\.\d{3})+(,\d+)?$"# : #"^\d{1,3}(,\d{3})+(\.\d+)?$"#
        if text.range(of: groupPattern, options: .regularExpression) != nil {
            text.removeAll { $0 == thousands }
        }
        // What remains: the language's decimal mark, or the other mark used as one ("1.5").
        text = String(text.map { $0 == decimal || $0 == thousands ? "." : $0 })
        guard text.filter({ $0 == "." }).count <= 1 else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func isEmoji(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.properties.isEmojiPresentation { return true }
        return scalar.properties.isEmoji && character.unicodeScalars.count > 1 && scalar.value > 0x238C
    }

    static func matches(_ pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    /// Names the tagger finds — personal names, places, organisations — as single words,
    /// skipping anything the tagger does not also class as a noun (a sentence-initial
    /// "Te" or "I'm" capitalised by position, not a name) and the given interjections.
    static func names(in text: String, excluding interjections: Set<String>) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
        tagger.string = text
        var names: [String] = []
        let wanted: Set<NLTag> = [.personalName, .placeName, .organizationName]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            guard let tag, wanted.contains(tag) else { return true }
            for word in text[range].split(whereSeparator: \.isWhitespace) {
                // The tagger may keep a title's period ("Sr."): compare the letters only.
                let token = String(word).trimmingCharacters(in: .punctuationCharacters)
                let folded = token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                guard token.count >= 2, !interjections.contains(folded) else { continue }
                guard !token.isEmpty else { continue }
                if let start = text.range(of: token, range: range),
                   let lexical = tagger.tag(at: start.lowerBound, unit: .word, scheme: .lexicalClass).0,
                   ![NLTag.noun, .otherWord].contains(lexical) {
                    continue
                }
                names.append(token)
            }
            return true
        }
        return names
    }

    /// The dominant language and the two most likely ones.
    static func language(of text: String) -> (dominant: String?, likely: [String]) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let likely = recognizer.languageHypotheses(withMaximum: 2).sorted { $0.value > $1.value }.map(\.key.rawValue)
        return (recognizer.dominantLanguage?.rawValue, likely)
    }
}
