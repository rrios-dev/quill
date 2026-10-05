import Foundation
import QuillSupport

extension Bundle {
    /// RewriteKit's resources (prompt texts, word lists, built-ins), resolved inside the
    /// packaged app first (ARCHITECTURE §8).
    static let rewriteKit = ResourceBundle.resolve("Quill_RewriteKit", fallback: .module)
}

/// Loads RewriteKit's JSON resources. Spanish text — fixtures, word lists, prompt
/// texts — lives in these files, never in Swift source (language policy).
enum RewriteResources {
    enum LoadError: Error, Equatable {
        case missing(String)
        case unreadable(String, String)
    }

    static func data(_ name: String) throws(LoadError) -> Data {
        guard let url = Bundle.rewriteKit.url(forResource: name, withExtension: "json") else {
            throw .missing(name)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw .unreadable(name, "\(error)")
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from name: String) throws(LoadError) -> T {
        let data = try data(name)
        do {
            return try RewriteKitCoding.decoder().decode(T.self, from: data)
        } catch {
            throw .unreadable(name, "\(error)")
        }
    }
}

/// The one JSON encoding of RewriteKit's files: readable, stable key order, ISO 8601
/// dates with milliseconds (ARCHITECTURE §4.2).
///
/// Dates are handled as whole milliseconds: `Date.roundedToMilliseconds` and the
/// coder compute the same `Double(milliseconds) / 1000`, so a value read back is
/// exactly the value written. A plain ISO 8601 formatter truncates the fraction, and a
/// value a hair below a millisecond boundary would come back one millisecond early.
public enum RewriteKitCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
            }
            return date
        }
        return decoder
    }

    static let wholeSeconds = Date.ISO8601FormatStyle()

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    /// `2026-10-03T19:29:57.123Z`.
    static func string(from date: Date) -> String {
        let ms = milliseconds(date)
        let seconds = ms >= 0 ? ms / 1000 : (ms - 999) / 1000
        let fraction = ms - seconds * 1000
        let base = Date(timeIntervalSince1970: Double(seconds)).formatted(wholeSeconds)
        return base.replacingOccurrences(of: "Z", with: String(format: ".%03lldZ", fraction))
    }

    static func date(from text: String) -> Date? {
        guard text.hasSuffix("Z") else { return nil }
        var whole = text
        var fraction: Int64 = 0
        if let dot = text.lastIndex(of: ".") {
            let digits = text[text.index(after: dot)..<text.index(before: text.endIndex)]
            guard (1...3).contains(digits.count), let value = Int64(digits) else { return nil }
            fraction = value * Int64([1, 100, 10, 1][digits.count])
            whole = String(text[..<dot]) + "Z"
        }
        guard let seconds = try? Date(whole, strategy: wholeSeconds) else { return nil }
        return date(milliseconds: Int64(seconds.timeIntervalSince1970.rounded()) * 1000 + fraction)
    }
}

/// Loads every RewriteKit resource the way a rewrite would, for the app's `--self-check`
/// (ARCHITECTURE §8): word lists load lazily on the first rewrite, so a missing bundle
/// would otherwise surface only then, on someone else's Mac.
public enum RewriteKitSelfCheck {
    /// Returns the bundle the resources came from.
    @discardableResult
    public static func run() throws -> URL {
        _ = try BuiltInProfiles.all(language: "en")
        _ = try AbbreviationTable.load()
        _ = try PromptComposer()
        _ = try OutputGuards()
        return Bundle.rewriteKit.bundleURL
    }
}
