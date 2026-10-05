import Foundation

/// The shipped profiles' ids, persisted in `Profile.builtIn` (PRODUCT §5).
public enum BuiltInProfile: String, Codable, CaseIterable, Sendable {
    case spelling, work, formal, friends, dictation, concise, synthesis

    /// The built-ins the app installs: those the bench confirmed ready on at least one
    /// hosted model (BENCH §1.1, the shipping rule). The others are still defined and
    /// measured — the bench runs every case — but the app does not seed, restore or list
    /// them until they pass. Synthesize did not pass its gate on 2026-10-05 (README).
    public static let shipped: [BuiltInProfile] = allCases.filter { $0 != .synthesis }

    public var isShipped: Bool { Self.shipped.contains(self) }
}

/// The built-in profiles, from `builtins.json` (PRODUCT §5): editable starting
/// points, each with two shipped examples kept disjoint from the bench's cases and from
/// PRODUCT's worked examples.
public enum BuiltInProfiles {
    struct File: Decodable {
        let schemaVersion: Int
        let profiles: [Entry]
    }

    struct Entry: Decodable {
        let id: BuiltInProfile
        let names: [String: String]
        let symbol: String
        let settings: ProfileSettings
        /// Behaviour PRODUCT §5 describes that the settings cannot express — Friends'
        /// opening ¿ ¡, Formal's "vague stays vague". Short enough to be sent whole
        /// to small models (60 words, ARCHITECTURE §4.4).
        /// Per language; the profile gets the one of the language it is created in.
        let guidance: [String: String]?
        let examples: [ShippedExample]
    }

    struct ShippedExample: Decodable {
        let input: String
        let output: String
    }

    static func entries() throws(RewriteResources.LoadError) -> [BuiltInProfile: Entry] {
        let file = try RewriteResources.decode(File.self, from: "builtins")
        return Dictionary(uniqueKeysWithValues: file.profiles.map { ($0.id, $0) })
    }

    /// A fresh copy of a built-in, named in `language` ("es" or "en"; others get English).
    public static func make(
        _ id: BuiltInProfile, language: String, now: Date = Date()
    ) throws -> Profile {
        guard let entry = try entries()[id] else { throw RewriteResources.LoadError.missing("builtins.\(id.rawValue)") }
        let profile = Profile(
            name: entry.names[language] ?? entry.names["en"] ?? id.rawValue,
            symbol: entry.symbol,
            builtIn: id,
            settings: entry.settings,
            guidance: entry.guidance?[language] ?? entry.guidance?["en"] ?? "",
            examples: entry.examples.map { Example(input: $0.input, output: $0.output, addedAt: now) },
            updatedAt: now)
        try profile.validate()
        return profile
    }

    /// The shipped built-ins, in PRODUCT §5's order (the order of the picker's numbers).
    public static func all(language: String, now: Date = Date()) throws -> [Profile] {
        try BuiltInProfile.shipped.map { try make($0, language: language, now: now) }
    }

    /// Whether `profile` carries text the user wrote — an example that is not one of its
    /// built-in's shipped pairs, or guidance other than the shipped guidance in any
    /// language. Only that text triggers the new-recipient notice (ARCHITECTURE §5.3):
    /// shipped examples and guidance do not count.
    public static func hasUserAuthoredText(_ profile: Profile) -> Bool {
        let entry = profile.builtIn.flatMap { try? entries()[$0] }
        let shippedPairs = Set((entry?.examples ?? []).map { "\($0.input)\u{0}\($0.output)" })
        if profile.examples.contains(where: { !shippedPairs.contains("\($0.input)\u{0}\($0.output)") }) { return true }
        let guidance = profile.guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !guidance.isEmpty else { return false }
        let shippedGuidance = Set((entry?.guidance ?? [:]).values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        return !shippedGuidance.contains(guidance)
    }

    /// The shipped example pairs of a built-in, as written — the bench's disjointness
    /// test and `check-references` read them (BENCH §2).
    public static func shippedExamples(_ id: BuiltInProfile) throws -> [(input: String, output: String)] {
        guard let entry = try entries()[id] else { return [] }
        return entry.examples.map { ($0.input, $0.output) }
    }
}

/// The shared chat-abbreviation table (`abbreviations.json`): used by profiles that
/// expand abbreviations and by the guards' normalisation (G6, G9, G13).
public struct AbbreviationTable: Sendable {
    /// Lowercased abbreviation → expansion, per language code.
    public let languages: [String: [String: String]]

    struct File: Decodable {
        let schemaVersion: Int
        let languages: [String: [String: String]]
    }

    public static func load() throws -> AbbreviationTable {
        let file = try RewriteResources.decode(File.self, from: "abbreviations")
        return AbbreviationTable(languages: file.languages.mapValues { table in
            Dictionary(uniqueKeysWithValues: table.map { ($0.key.lowercased(), $0.value) })
        })
    }

    /// The expansion of `token` in `language`, or in any language when nil.
    public func expansion(of token: String, language: String? = nil) -> String? {
        let key = token.lowercased()
        if let language { return languages[language]?[key] }
        // A fixed order, so an abbreviation listed in two languages always resolves alike.
        for language in languages.keys.sorted() {
            if let value = languages[language]?[key] { return value }
        }
        return nil
    }
}
