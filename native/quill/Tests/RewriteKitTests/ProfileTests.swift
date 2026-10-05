import Foundation
import ModelKit
import Testing

@testable import RewriteKit

@Suite("Profiles")
struct ProfileTests {
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try RewriteKitCoding.decoder().decode(T.self, from: RewriteKitCoding.encoder().encode(value))
    }

    private func profile(
        name: String = "Work", guidance: String = "", examples: [Example] = [],
        settings: ProfileSettings = ProfileSettings(scope: .rewrite), temperature: Double? = nil, version: Int = 1
    ) -> Profile {
        Profile(name: name, symbol: "briefcase", settings: settings, guidance: guidance, examples: examples,
                temperature: temperature, version: version)
    }

    // MARK: Round trip

    @Test("a profile survives encoding and decoding unchanged, dates included")
    func losslessRoundTrip() throws {
        let original = Profile(
            name: "Legal (EN)", symbol: "building.columns", builtIn: .formal,
            settings: ProfileSettings(scope: .rewrite, register: .formal, tone: .neutral, length: .shorter,
                                      abbreviations: .expand, interjections: .remove, emoji: .remove,
                                      preserve: [.names, .links], targetLanguage: "en-GB",
                                      lengthBand: .init(0.5, 1.5)),
            guidance: "Prefer plain words over legalese.",
            examples: [Example(input: "pls send it", output: "Please send it.", addedAt: Date(timeIntervalSince1970: 1_759_500_000.123456))],
            model: ModelSelection(provider: "openrouter", model: "vendor/model"),
            temperature: 0.2, version: 7, updatedAt: Date())
        #expect(try roundTrip(original) == original)
    }

    @Test("samples and their results survive a round trip")
    func samplesRoundTrip() throws {
        let set = SampleSet(samples: [
            Sample(text: "first sample text", currentResult: SampleResult(
                profileVersion: 3, model: ModelSelection(provider: "apple.on-device", model: "system"), text: "First sample text.")),
        ])
        #expect(try roundTrip(set) == set)
    }

    @Test("the encoding is readable: ISO 8601 dates and a sorted preserve list")
    func readableEncoding() throws {
        let json = String(decoding: try RewriteKitCoding.encoder().encode(profile()), as: UTF8.self)
        #expect(json.contains(#""preserve" : ["#))
        #expect(json.range(of: #""updatedAt" : "\d{4}-\d{2}-\d{2}T"#, options: .regularExpression) != nil)
        let decoded = try RewriteKitCoding.decoder().decode(Profile.self, from: Data(json.utf8))
        #expect(decoded.settings.preserve == Set(ProfileSettings.Preserved.allCases))
    }

    // MARK: Caps

    private func expectError(_ expected: ProfileError, _ profile: Profile, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: expected, sourceLocation: sourceLocation) { try profile.validate() }
    }

    @Test("every cap is a typed error, never a silent truncation")
    func caps() {
        expectError(.nameEmpty, profile(name: "  "))
        expectError(.nameTooLong(41), profile(name: String(repeating: "n", count: 41)))
        expectError(.guidanceTooLong(601), profile(guidance: String(repeating: "g", count: 601)))
        expectError(.tooManyExamples(9), profile(examples: (0..<9).map { Example(input: "in \($0)", output: "out \($0)") }))
        let long = Example(input: String(repeating: "i", count: 501), output: "short")
        expectError(.exampleTooLong(long.id, side: .input, 501), profile(examples: [long]))
        let longOutput = Example(input: "short", output: String(repeating: "o", count: 501))
        expectError(.exampleTooLong(longOutput.id, side: .output, 501), profile(examples: [longOutput]))
        let empty = Example(input: " ", output: "x")
        expectError(.exampleEmpty(empty.id), profile(examples: [empty]))
        let twin = Example(input: "a", output: "b")
        expectError(.duplicateExample(twin.id), profile(examples: [twin, twin]))
        expectError(.temperatureOutOfRange(2.5), profile(temperature: 2.5))
        expectError(.temperatureOutOfRange(-0.1), profile(temperature: -0.1))
        expectError(.invalidVersion(0), profile(version: 0))
        var noSymbol = profile()
        noSymbol.symbol = ""
        expectError(.symbolEmpty, noSymbol)
    }

    @Test("the limits themselves are accepted")
    func atTheLimits() throws {
        try profile(
            name: String(repeating: "n", count: 40), guidance: String(repeating: "g", count: 600),
            examples: (0..<8).map { _ in Example(input: String(repeating: "i", count: 500), output: String(repeating: "o", count: 500)) },
            temperature: 2
        ).validate()
    }

    @Test("decoding rejects an invalid profile with its typed error")
    func decodeValidates() throws {
        var invalid = profile()
        invalid.name = String(repeating: "n", count: 41)
        let data = try RewriteKitCoding.encoder().encode(invalid)
        #expect(throws: ProfileError.nameTooLong(41)) { try RewriteKitCoding.decoder().decode(Profile.self, from: data) }
    }

    @Test("sample caps")
    func sampleCaps() {
        let tooLong = Sample(text: String(repeating: "s", count: 1_001))
        #expect(throws: ProfileError.sampleTooLong(tooLong.id, 1_001)) { try tooLong.validate() }
        let many = SampleSet(samples: (0..<11).map { Sample(text: "sample \($0)") })
        #expect(throws: ProfileError.tooManySamples(11)) { try many.validate() }
    }

    // MARK: spellingOnly rules (PRODUCT §5)

    @Test("spelling-only profiles keep the register and the language")
    func spellingOnlyRules() throws {
        let registerChange = profile(settings: ProfileSettings(scope: .spellingOnly, register: .formal))
        expectError(.spellingOnlyChangesRegister, registerChange)
        let translation = profile(settings: ProfileSettings(scope: .spellingOnly, targetLanguage: "en"))
        expectError(.spellingOnlyTranslates, translation)
        // Tone, length and interjections are inert, not invalid.
        let inert = ProfileSettings(scope: .spellingOnly, tone: .warm, length: .shorter, interjections: .remove)
        try profile(settings: inert).validate()
        #expect(inert.inertFields == ["tone", "length", "interjections"])
        #expect(ProfileSettings(scope: .rewrite).inertFields.isEmpty)
    }

    @Test("target languages and length bands are checked")
    func settingsChecks() {
        expectError(.invalidTargetLanguage("English"), profile(settings: ProfileSettings(scope: .rewrite, targetLanguage: "English")))
        expectError(.invalidLengthBand(minimum: 1.5, maximum: 1.2),
                    profile(settings: ProfileSettings(scope: .rewrite, lengthBand: .init(1.5, 1.2))))
        expectError(.invalidLengthBand(minimum: 0, maximum: 1),
                    profile(settings: ProfileSettings(scope: .rewrite, lengthBand: .init(0, 1))))
        #expect(ProfileSettings.isLanguageCode("zh-Hans"))
        #expect(!ProfileSettings.isLanguageCode("EN"))
    }

    // MARK: Built-ins (PRODUCT §5)

    /// PRODUCT §5's table, transcribed.
    static let productTable: [BuiltInProfile: ProfileSettings] = [
        .spelling: ProfileSettings(
            scope: .spellingOnly, register: .keep, tone: .keep, length: .keep, abbreviations: .expand,
            interjections: .keep, emoji: .keep, preserve: [.names, .numbers, .links, .lineBreaks],
            targetLanguage: nil, lengthBand: .init(0.8, 1.8)),
        .work: ProfileSettings(
            scope: .rewrite, register: .keep, tone: .cordial, length: .keep, abbreviations: .expand,
            interjections: .remove, emoji: .keep, preserve: [.names, .numbers, .links],
            targetLanguage: nil, lengthBand: .init(0.6, 1.6)),
        .formal: ProfileSettings(
            scope: .rewrite, register: .formal, tone: .neutral, length: .keep, abbreviations: .expand,
            interjections: .remove, emoji: .remove, preserve: [.names, .numbers, .links, .lineBreaks],
            targetLanguage: nil, lengthBand: .init(0.7, 1.8)),
        .friends: ProfileSettings(
            scope: .spellingOnly, register: .keep, tone: .keep, length: .keep, abbreviations: .keep,
            interjections: .keep, emoji: .keep, preserve: [.names, .numbers, .links, .lineBreaks],
            targetLanguage: nil, lengthBand: .init(0.8, 1.4)),
        .dictation: ProfileSettings(
            scope: .spellingOnly, register: .keep, tone: .keep, length: .keep, abbreviations: .expand,
            interjections: .remove, emoji: .keep, preserve: [.names, .numbers, .links, .lineBreaks],
            targetLanguage: nil, lengthBand: .init(0.5, 1.1)),
        .concise: ProfileSettings(
            scope: .rewrite, register: .keep, tone: .keep, length: .shorter, abbreviations: .expand,
            interjections: .remove, emoji: .keep, preserve: [.names, .numbers, .links],
            targetLanguage: nil, lengthBand: .init(0.3, 1.05)),
        .synthesis: ProfileSettings(
            scope: .rewrite, register: .keep, tone: .direct, length: .shorter, abbreviations: .expand,
            interjections: .remove, emoji: .remove, preserve: [.names, .numbers, .links],
            targetLanguage: nil, lengthBand: .init(0.1, 1.05)),
    ]

    @Test("each built-in's settings equal PRODUCT §5's table", arguments: BuiltInProfile.allCases)
    func builtInSettings(_ id: BuiltInProfile) throws {
        let builtIn = try BuiltInProfiles.make(id, language: "en")
        #expect(builtIn.settings == Self.productTable[id])
        #expect(builtIn.builtIn == id)
    }

    @Test("each built-in ships exactly two valid examples and a name in both languages", arguments: BuiltInProfile.allCases)
    func builtInExamplesAndNames(_ id: BuiltInProfile) throws {
        let spanish = try BuiltInProfiles.make(id, language: "es")
        let english = try BuiltInProfiles.make(id, language: "en")
        #expect(spanish.examples.count == 2)
        try spanish.validate()
        #expect(!spanish.name.isEmpty && !english.name.isEmpty)
        #expect(try BuiltInProfiles.shippedExamples(id).count == 2)
    }

    @Test("the built-ins come in PRODUCT's order with their ids; the first four keep their numbers")
    func builtInOrder() throws {
        let order: [BuiltInProfile] = [.spelling, .work, .formal, .friends, .dictation, .concise, .synthesis]
        #expect(try BuiltInProfiles.all(language: "es").map(\.builtIn) == order.filter(\.isShipped))
        #expect(BuiltInProfile.shipped == [.spelling, .work, .formal, .friends, .dictation, .concise],
                "the shipping rule: Synthesize waits for its gate (README)")
        #expect(BuiltInProfile.allCases.map(\.rawValue) == ["spelling", "work", "formal", "friends", "dictation", "concise", "synthesis"])
    }

    // MARK: Abbreviations

    @Test("the shared abbreviation table loads, and laughter is not an abbreviation")
    func abbreviations() throws {
        let table = try AbbreviationTable.load()
        #expect(table.expansion(of: "XQ", language: "es") == "porque")
        #expect(table.expansion(of: "tmrw", language: "en") == "tomorrow")
        #expect(table.expansion(of: "u") == "you")
        for laughter in ["jaja", "jajaja", "lol", "omg", "oye", "hey"] {
            #expect(table.expansion(of: laughter) == nil, "\(laughter)")
        }
    }
}

@Suite("Date coding")
struct DateCodingTests {
    @Test("a millisecond date is written and read back exactly, for many values")
    func exact() throws {
        for step in 0..<2_000 {
            let date = Date(timeIntervalSince1970: 1_759_500_000 + Double(step) * 0.0013337).roundedToMilliseconds
            let text = RewriteKitCoding.string(from: date)
            #expect(RewriteKitCoding.date(from: text) == date, "\(text)")
        }
    }

    @Test("the text is ISO 8601 with milliseconds, and malformed text is rejected")
    func format() {
        let date = Date(timeIntervalSince1970: 1_759_519_797.5)
        #expect(RewriteKitCoding.string(from: date) == "2025-10-03T19:29:57.500Z")
        #expect(RewriteKitCoding.date(from: "2025-10-03T19:29:57Z") == Date(timeIntervalSince1970: 1_759_519_797))
        #expect(RewriteKitCoding.date(from: "2025-10-03T19:29:57.5Z") == date)
        #expect(RewriteKitCoding.date(from: "yesterday") == nil)
        #expect(RewriteKitCoding.date(from: "2025-10-03T19:29:57.12345Z") == nil)
    }
}
