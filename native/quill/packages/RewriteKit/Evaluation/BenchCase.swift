import Foundation

/// RewriteKit's evaluation version. Bumped whenever a guard, a guard word list or the
/// evaluation changes: a verdict measured with older guards is not reused (ARCHITECTURE
/// §5.1), and the gate's run count resets (BENCH §1.1).
public enum RewriteKitVersion {
    /// 2: G2 no longer flags a bracketed link the input already had (P1-T8).
    public static let evaluation = 2
}

/// The fixed category vocabulary of BENCH §2.1.
public enum BenchCategory: String, Codable, CaseIterable, Sendable {
    case chatShorthand, alreadyCorrect, preservedTokens, whoDidWhat, register, injection
    case noAddedFormulas, english, nearContextLimit, exampleBait, multiLine, noAddedFacts, refusalBait

    /// A case is critical exactly when one of its categories is.
    public var isCritical: Bool {
        switch self {
        case .alreadyCorrect, .whoDidWhat, .injection, .noAddedFormulas: true
        default: false
        }
    }
}

/// One input for one profile, and what a good output looks like (BENCH §2).
public struct BenchCase: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var profile: BuiltInProfile
    public var language: String
    public var categories: [BenchCategory]
    public var critical: Bool
    public var input: String
    public var expectChange: Bool
    public var references: [String]
    /// Meaning anchors — nouns, names, dates, numbers — never verbs a valid rewrite may change.
    public var mustKeep: [String]
    public var mustNotContain: [String]
    public var notes: String?
    /// `exampleBait` only: added first to the profile's examples for this case.
    public var injectExample: InjectedExample?
    /// Holdout retirement (BENCH §2.3): kept, excluded from verdicts.
    public var retired: Bool?
    public var retiredReason: String?

    public struct InjectedExample: Codable, Hashable, Sendable {
        public var input: String
        public var output: String

        public init(input: String, output: String) {
            self.input = input
            self.output = output
        }
    }

    public init(
        id: String, profile: BuiltInProfile, language: String, categories: [BenchCategory], critical: Bool,
        input: String, expectChange: Bool, references: [String], mustKeep: [String] = [],
        mustNotContain: [String] = [], notes: String? = nil, injectExample: InjectedExample? = nil,
        retired: Bool? = nil, retiredReason: String? = nil
    ) {
        self.id = id
        self.profile = profile
        self.language = language
        self.categories = categories
        self.critical = critical
        self.input = input
        self.expectChange = expectChange
        self.references = references
        self.mustKeep = mustKeep
        self.mustNotContain = mustNotContain
        self.notes = notes
        self.injectExample = injectExample
        self.retired = retired
        self.retiredReason = retiredReason
    }

    public var isRetired: Bool { retired ?? false }

    /// The pinned example the engine receives for this case.
    public var pinnedExample: Example? {
        injectExample.map { Example(input: $0.input, output: $0.output, addedAt: Date(timeIntervalSince1970: 0)) }
    }
}

/// A judge's scores, 1–5 per dimension (BENCH §1.2).
public struct JudgeScores: Codable, Hashable, Sendable {
    /// Meaning preserved, including who does what to whom.
    public var meaning: Double
    /// Matches the profile: register, tone, abbreviations, interjections, emoji.
    public var profileMatch: Double
    public var nothingAdded: Double
    public var fluency: Double

    public init(meaning: Double, profileMatch: Double, nothingAdded: Double, fluency: Double) {
        self.meaning = meaning
        self.profileMatch = profileMatch
        self.nothingAdded = nothingAdded
        self.fluency = fluency
    }

    public var mean: Double { (meaning + profileMatch + nothingAdded + fluency) / 4 }
    public var lowest: Double { min(meaning, profileMatch, nothingAdded, fluency) }
}
