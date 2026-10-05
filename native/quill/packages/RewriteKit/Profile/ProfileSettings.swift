import Foundation

/// The structured settings every profile has (PRODUCT §5).
///
/// Named `ProfileSettings`, not `Settings`, so it never collides with SwiftUI's
/// `Settings` scene in the app (ARCHITECTURE §4.1).
public struct ProfileSettings: Codable, Hashable, Sendable {
    public enum Scope: String, Codable, CaseIterable, Sendable {
        /// Fix errors, keep the wording.
        case spellingOnly
        /// Rephrase.
        case rewrite
    }

    public enum Register: String, Codable, CaseIterable, Sendable {
        case keep
        /// Spanish: tú.
        case informal
        /// Spanish: usted; English: formal, no contractions.
        case formal
    }

    public enum Tone: String, Codable, CaseIterable, Sendable {
        case keep, neutral, cordial, warm, direct
    }

    public enum Length: String, Codable, CaseIterable, Sendable {
        case keep, shorter, longer
    }

    public enum Abbreviations: String, Codable, CaseIterable, Sendable {
        /// q → que, u → you.
        case expand
        case keep
    }

    public enum Interjections: String, Codable, CaseIterable, Sendable {
        case keep
        /// oye, tío, hey, lol.
        case remove
    }

    public enum Emoji: String, Codable, CaseIterable, Sendable {
        case keep, remove
    }

    /// What a rewrite must carry over unchanged; guard G3 checks each.
    public enum Preserved: String, Codable, CaseIterable, Comparable, Sendable {
        case names, numbers, links, lineBreaks

        public static func < (lhs: Self, rhs: Self) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// The output/input word ratio accepted without a flag (guard G5).
    public struct LengthBand: Codable, Hashable, Sendable {
        public var minimum: Double
        public var maximum: Double

        public init(_ minimum: Double, _ maximum: Double) {
            self.minimum = minimum
            self.maximum = maximum
        }

        public func contains(_ ratio: Double) -> Bool { ratio >= minimum && ratio <= maximum }
    }

    public var scope: Scope
    public var register: Register
    public var tone: Tone
    public var length: Length
    public var abbreviations: Abbreviations
    public var interjections: Interjections
    public var emoji: Emoji
    public var preserve: Set<Preserved>
    /// A language code ("en", "es"); nil keeps the input's language.
    public var targetLanguage: String?
    public var lengthBand: LengthBand

    public init(
        scope: Scope, register: Register = .keep, tone: Tone = .keep, length: Length = .keep,
        abbreviations: Abbreviations = .expand, interjections: Interjections = .keep, emoji: Emoji = .keep,
        preserve: Set<Preserved> = Set(Preserved.allCases), targetLanguage: String? = nil,
        lengthBand: LengthBand = LengthBand(0.8, 1.8)
    ) {
        self.scope = scope
        self.register = register
        self.tone = tone
        self.length = length
        self.abbreviations = abbreviations
        self.interjections = interjections
        self.emoji = emoji
        self.preserve = preserve
        self.targetLanguage = targetLanguage
        self.lengthBand = lengthBand
    }

    /// Fields that have no effect under `spellingOnly`: left out of the prompt and
    /// greyed out in the editor (PRODUCT §5).
    public var inertFields: Set<String> {
        scope == .spellingOnly ? ["tone", "length", "interjections"] : []
    }

    /// The `spellingOnly` rules and the band's bounds; the profile reports the error.
    func validate() throws(ProfileError) {
        if scope == .spellingOnly {
            guard register == .keep else { throw .spellingOnlyChangesRegister }
            guard targetLanguage == nil else { throw .spellingOnlyTranslates }
        }
        if let targetLanguage {
            guard Self.isLanguageCode(targetLanguage) else { throw .invalidTargetLanguage(targetLanguage) }
        }
        guard lengthBand.minimum > 0, lengthBand.minimum < lengthBand.maximum,
              lengthBand.maximum <= ProfileLimits.maximumLengthRatio
        else { throw .invalidLengthBand(minimum: lengthBand.minimum, maximum: lengthBand.maximum) }
    }

    /// Two or three lowercase letters, optionally a region or script: "es", "en-GB", "zh-Hans".
    static func isLanguageCode(_ code: String) -> Bool {
        let parts = code.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = parts.first, (2...3).contains(language.count),
              language.allSatisfy({ $0.isASCII && $0.isLowercase }) else { return false }
        return parts.dropFirst().allSatisfy { (2...4).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isLetter } }
    }

    // A stable, readable encoding: `preserve` sorted, so files diff cleanly.
    enum CodingKeys: String, CodingKey {
        case scope, register, tone, length, abbreviations, interjections, emoji, preserve, targetLanguage, lengthBand
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scope, forKey: .scope)
        try container.encode(register, forKey: .register)
        try container.encode(tone, forKey: .tone)
        try container.encode(length, forKey: .length)
        try container.encode(abbreviations, forKey: .abbreviations)
        try container.encode(interjections, forKey: .interjections)
        try container.encode(emoji, forKey: .emoji)
        try container.encode(preserve.sorted(), forKey: .preserve)
        try container.encodeIfPresent(targetLanguage, forKey: .targetLanguage)
        try container.encode(lengthBand, forKey: .lengthBand)
    }
}
