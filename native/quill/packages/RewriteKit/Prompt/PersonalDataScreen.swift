import Foundation

/// The deterministic personal-identifier screen the memory-layer mould asks for
/// (ARCHITECTURE §4.3): run when examples, guidance and samples are saved, and again
/// when a prompt is composed — the exclusion list may grow, and what passed last month
/// must stop travelling today.
///
/// It looks for identifiers, not topics: examples are pairs the user wrote and chose,
/// so what must not travel unnoticed is an e-mail address or an IBAN, not a subject.
public enum PersonalDataScreen {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case email
        case phone
        case iban
        case card
        /// Spanish DNI or NIE.
        case nationalID
    }

    /// The kinds of identifier found in `text`, in a fixed order.
    public static func findings(in text: String) -> Set<Kind> {
        var found = Set<Kind>()
        if matches(emailPattern, in: text) { found.insert(.email) }
        if containsIBAN(text) { found.insert(.iban) }
        if containsCard(text) { found.insert(.card) }
        if containsNationalID(text) { found.insert(.nationalID) }
        if containsPhone(text) { found.insert(.phone) }
        return found
    }

    public static func isClean(_ text: String) -> Bool { findings(in: text).isEmpty }

    /// `text` with neutral stand-ins for what the screen looks for: an e-mail address
    /// becomes `someone@example`, and every digit in a run of five or more (phones,
    /// IBANs, cards, DNI/NIE numbers) becomes `X` — so the result passes the screen and
    /// keeps the shape of the sentence, which is what an example teaches.
    public static func withStandIns(_ text: String) -> String {
        var result = text
        if let email = try? NSRegularExpression(pattern: emailPattern) {
            result = email.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "someone@example")
        }
        guard let run = try? NSRegularExpression(pattern: #"[0-9][0-9 .\-]{3,}[0-9]"#) else { return result }
        var output = ""
        var cursor = result.startIndex
        for match in run.matches(in: result, range: NSRange(result.startIndex..., in: result)) {
            guard let range = Range(match.range, in: result) else { continue }
            let digits = result[range].filter(\.isNumber).count
            output += result[cursor..<range.lowerBound]
            output += digits >= 5 ? String(result[range].map { $0.isNumber ? "X" : $0 }) : String(result[range])
            cursor = range.upperBound
        }
        output += result[cursor...]
        return output
    }

    // MARK: E-mail

    static let emailPattern = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#

    // MARK: IBAN — country code, check digits, 11–30 alphanumerics, mod-97 = 1

    static func containsIBAN(_ text: String) -> Bool {
        let pattern = #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]){11,30}\b"#
        // The pattern may run on into the next words ("… 1332 WHEN"), so every prefix
        // of a valid IBAN length is checked.
        return candidates(pattern, in: text.uppercased()).contains { candidate in
            let compact = candidate.replacingOccurrences(of: " ", with: "")
            return (15...min(34, compact.count)).contains { isValidIBAN(String(compact.prefix($0))) }
        }
    }

    static func isValidIBAN(_ iban: String) -> Bool {
        guard (15...34).contains(iban.count) else { return false }
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0
        for character in rearranged {
            guard let value = character.isNumber ? character.wholeNumberValue
                    : character.asciiValue.map({ Int($0) - 55 }) else { return false }
            for digit in String(value) {
                remainder = (remainder * 10 + digit.wholeNumberValue!) % 97
            }
        }
        return remainder == 1
    }

    // MARK: Cards — 13–19 digits with spaces or dashes, Luhn-valid

    static func containsCard(_ text: String) -> Bool {
        candidates(#"\b\d(?:[ \-]?\d){12,18}\b"#, in: text).contains { candidate in
            isLuhnValid(candidate.filter(\.isNumber))
        }
    }

    static func isLuhnValid(_ digits: String) -> Bool {
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard var digit = character.wholeNumberValue else { return false }
            if index % 2 == 1 {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
        }
        return sum % 10 == 0
    }

    // MARK: DNI / NIE — the control letter must match

    static let controlLetters = Array("TRWAGMYFPDXBNJZSQVHLCKE")

    static func containsNationalID(_ text: String) -> Bool {
        candidates(#"\b[XYZxyz]?\d{7,8}[ \-]?[A-Za-z]\b"#, in: text).contains { isValidNationalID($0) }
    }

    static func isValidNationalID(_ candidate: String) -> Bool {
        var id = candidate.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        // An NIE's leading X, Y or Z stands for 0, 1 or 2 in the checksum.
        let nieDigits: [Character: Character] = ["X": "0", "Y": "1", "Z": "2"]
        if let first = id.first, let digit = nieDigits[first] {
            id = String(digit) + id.dropFirst()
        }
        guard id.count == 9, let letter = id.last, let number = Int(id.dropLast()) else { return false }
        return controlLetters[number % 23] == letter
    }

    // MARK: Phones — 9 or more digits in a phone-like run, not a card or an ID

    static func containsPhone(_ text: String) -> Bool {
        let pattern = #"(?:\+\d{1,3}[ .\-]?)?(?:\(?\d{2,4}\)?[ .\-]?){2,5}\d{2,4}"#
        return candidates(pattern, in: text).contains { candidate in
            let digits = candidate.filter(\.isNumber)
            guard (9...13).contains(digits.count) else { return false }
            // Thousands in prose ("1.000.000"), decimals and ISO dates are not phones.
            if candidate.range(of: #"^\d{1,3}(?:[.,]\d{3})+(?:[.,]\d+)?$"#, options: .regularExpression) != nil
                || candidate.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
                return false
            }
            return !isLuhnValid(digits) || digits.count < 13
        }
    }

    // MARK: Helpers

    static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static func candidates(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}
