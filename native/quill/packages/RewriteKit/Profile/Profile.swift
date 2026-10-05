import Foundation
import ModelKit

/// A named way of rewriting (PRODUCT §2, ARCHITECTURE §4.1).
///
/// Validated when decoded and before it is saved: an invalid profile is rejected with
/// a typed `ProfileError`, never truncated silently.
public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// 1–40 characters.
    public var name: String
    /// An SF Symbol name.
    public var symbol: String
    /// Which shipped profile it started from; nil for one the user created.
    public var builtIn: BuiltInProfile?
    public var settings: ProfileSettings
    /// Free text, ≤ 600 characters.
    public var guidance: String
    /// ≤ 8, each side ≤ 500 characters. A memory layer (ARCHITECTURE §4.3).
    public var examples: [Example]
    /// The pinned model; nil uses the global choice. Never substituted (README D-16).
    public var model: ModelSelection?
    /// nil omits the option, so each model keeps its own default.
    public var temperature: Double?
    /// Starts at 1; every saved edit adds one.
    public var version: Int
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), name: String, symbol: String, builtIn: BuiltInProfile? = nil,
        settings: ProfileSettings, guidance: String = "", examples: [Example] = [],
        model: ModelSelection? = nil, temperature: Double? = nil, version: Int = 1, updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.builtIn = builtIn
        self.settings = settings
        self.guidance = guidance
        self.examples = examples
        self.model = model
        self.temperature = temperature
        self.version = version
        self.updatedAt = updatedAt.roundedToMilliseconds
    }

    /// Every cap and rule of ARCHITECTURE §4.1/§4.3 and PRODUCT §5.
    public func validate() throws(ProfileError) {
        let nameLength = name.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard nameLength > 0 else { throw .nameEmpty }
        guard name.count <= ProfileLimits.nameCharacters else { throw .nameTooLong(name.count) }
        guard !symbol.trimmingCharacters(in: .whitespaces).isEmpty else { throw .symbolEmpty }
        guard guidance.count <= ProfileLimits.guidanceCharacters else { throw .guidanceTooLong(guidance.count) }
        guard examples.count <= ProfileLimits.examples else { throw .tooManyExamples(examples.count) }
        var seen = Set<UUID>()
        for example in examples {
            guard seen.insert(example.id).inserted else { throw .duplicateExample(example.id) }
            try example.validate()
        }
        if let temperature {
            guard temperature.isFinite, (0...ProfileLimits.maximumTemperature).contains(temperature)
            else { throw .temperatureOutOfRange(temperature) }
        }
        guard version >= 1 else { throw .invalidVersion(version) }
        try settings.validate()
    }

    enum CodingKeys: String, CodingKey {
        case id, name, symbol, builtIn, settings, guidance, examples, model, temperature, version, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            symbol: try container.decode(String.self, forKey: .symbol),
            builtIn: try container.decodeIfPresent(BuiltInProfile.self, forKey: .builtIn),
            settings: try container.decode(ProfileSettings.self, forKey: .settings),
            guidance: try container.decodeIfPresent(String.self, forKey: .guidance) ?? "",
            examples: try container.decodeIfPresent([Example].self, forKey: .examples) ?? [],
            model: try container.decodeIfPresent(ModelSelection.self, forKey: .model),
            temperature: try container.decodeIfPresent(Double.self, forKey: .temperature),
            version: try container.decode(Int.self, forKey: .version),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(symbol, forKey: .symbol)
        try container.encodeIfPresent(builtIn, forKey: .builtIn)
        try container.encode(settings, forKey: .settings)
        try container.encode(guidance, forKey: .guidance)
        try container.encode(examples, forKey: .examples)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encode(version, forKey: .version)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// An original → corrected pair the profile sends with every rewrite, shaped
/// `{id, text, at}` as the memory-layer mould asks (ARCHITECTURE §4.3).
public struct Example: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var input: String
    public var output: String
    public var addedAt: Date

    public init(id: UUID = UUID(), input: String, output: String, addedAt: Date = Date()) {
        self.id = id
        self.input = input
        self.output = output
        self.addedAt = addedAt.roundedToMilliseconds
    }

    public func validate() throws(ProfileError) {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw .exampleEmpty(id) }
        guard input.count <= ProfileLimits.exampleSideCharacters else { throw .exampleTooLong(id, side: .input, input.count) }
        guard output.count <= ProfileLimits.exampleSideCharacters else { throw .exampleTooLong(id, side: .output, output.count) }
    }

    enum CodingKeys: String, CodingKey { case id, input, output, addedAt }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            input: try container.decode(String.self, forKey: .input),
            output: try container.decode(String.self, forKey: .output),
            addedAt: try container.decode(Date.self, forKey: .addedAt))
        try validate()
    }
}

/// A Try it sample text, with what the current and the previous version produced
/// (PRODUCT F3). Lives beside the profile, not inside it (ARCHITECTURE §4.1).
public struct Sample: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// ≤ 1,000 characters.
    public var text: String
    public var addedAt: Date
    public var currentResult: SampleResult?
    public var previousResult: SampleResult?

    public init(id: UUID = UUID(), text: String, addedAt: Date = Date(),
                currentResult: SampleResult? = nil, previousResult: SampleResult? = nil) {
        self.id = id
        self.text = text
        self.addedAt = addedAt.roundedToMilliseconds
        self.currentResult = currentResult
        self.previousResult = previousResult
    }

    public func validate() throws(ProfileError) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .sampleEmpty(id) }
        guard text.count <= ProfileLimits.sampleCharacters else { throw .sampleTooLong(id, text.count) }
    }

    enum CodingKeys: String, CodingKey { case id, text, addedAt, currentResult, previousResult }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            text: try container.decode(String.self, forKey: .text),
            addedAt: try container.decode(Date.self, forKey: .addedAt),
            currentResult: try container.decodeIfPresent(SampleResult.self, forKey: .currentResult),
            previousResult: try container.decodeIfPresent(SampleResult.self, forKey: .previousResult))
        try validate()
    }
}

/// One Try it run of a sample: the text a profile version produced with a model.
public struct SampleResult: Codable, Hashable, Sendable {
    public var profileVersion: Int
    public var model: ModelSelection
    public var text: String
    public var date: Date

    public init(profileVersion: Int, model: ModelSelection, text: String, date: Date = Date()) {
        self.profileVersion = profileVersion
        self.model = model
        self.text = text
        self.date = date.roundedToMilliseconds
    }
}

/// A profile's Try it samples: ≤ 10 (ARCHITECTURE §4.2).
public struct SampleSet: Codable, Hashable, Sendable {
    public var samples: [Sample]

    public init(samples: [Sample] = []) { self.samples = samples }

    public func validate() throws(ProfileError) {
        guard samples.count <= ProfileLimits.samples else { throw .tooManySamples(samples.count) }
        for sample in samples { try sample.validate() }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        samples = try container.decode([Sample].self)
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(samples)
    }
}

/// The caps, in one place (ARCHITECTURE §4.1–§4.3).
public enum ProfileLimits {
    public static let nameCharacters = 40
    public static let guidanceCharacters = 600
    public static let examples = 8
    public static let exampleSideCharacters = 500
    public static let samples = 10
    public static let sampleCharacters = 1_000
    public static let maximumTemperature = 2.0
    /// The widest output/input word ratio a length band may accept.
    public static let maximumLengthRatio = 5.0
}

/// Why a profile, example or sample was rejected.
public enum ProfileError: Error, Hashable, Sendable {
    public enum Side: String, Sendable { case input, output }

    case nameEmpty
    case nameTooLong(Int)
    case symbolEmpty
    case guidanceTooLong(Int)
    case tooManyExamples(Int)
    case duplicateExample(UUID)
    case exampleEmpty(UUID)
    case exampleTooLong(UUID, side: Side, Int)
    case temperatureOutOfRange(Double)
    case invalidVersion(Int)
    /// Under `spellingOnly`, the register must be `keep` (PRODUCT §5).
    case spellingOnlyChangesRegister
    /// Under `spellingOnly`, there is no target language (PRODUCT §5).
    case spellingOnlyTranslates
    case invalidTargetLanguage(String)
    case invalidLengthBand(minimum: Double, maximum: Double)
    case tooManySamples(Int)
    case sampleEmpty(UUID)
    case sampleTooLong(UUID, Int)
}

extension Date {
    /// Dates are stored as whole milliseconds, so they are rounded to one when created;
    /// a round trip through the file is then exact (see `RewriteKitCoding`).
    var roundedToMilliseconds: Date {
        RewriteKitCoding.date(milliseconds: RewriteKitCoding.milliseconds(self))
    }
}
