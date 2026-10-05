import CryptoKit
import Foundation
import ModelKit
import NaturalLanguage

/// How much prompt a model gets (ARCHITECTURE §4.4).
public enum PromptStrategy: String, Codable, CaseIterable, Sendable {
    /// Small models (the on-device one): rules under 120 words, at most 60 words of
    /// guidance, guidance and examples within 600 tokens.
    case compact
    /// Everything else: the full rule set; guidance and examples within 1,500 tokens.
    case full

    public static func forContext(_ tokens: Int?) -> PromptStrategy {
        (tokens ?? .max) < ProviderTraits.smallContextThreshold ? .compact : .full
    }

    /// Tokens guidance and examples may take together (the memory-layer budget, §4.3).
    public var memoryBudgetTokens: Int { self == .compact ? 600 : 1_500 }

    /// Words of guidance sent; the editor marks the rest "not sent to small models".
    public var guidanceWordLimit: Int? { self == .compact ? 60 : nil }
}

/// A composed request, plus what was and was not sent and why.
public struct ComposedPrompt: Sendable {
    public var request: GenerationRequest
    public var strategy: PromptStrategy
    /// Identifies the prompt for readiness labels and gate verdicts (ARCHITECTURE §4.4).
    public var promptHash: String
    public var report: CompositionReport
}

public struct CompositionReport: Hashable, Sendable {
    public enum Guidance: Hashable, Sendable {
        case none
        case sent
        /// Compact strategy: only the first `words` words went.
        case truncated(words: Int)
        case skippedForPersonalData
    }

    /// The rule ids emitted, in order.
    public var rules: [String]
    public var guidance: Guidance
    /// Examples sent: the pinned one first, then the profile's — those in another language
    /// than the input first, each group in chronological order.
    public var sentExamples: [UUID]
    /// Over the budget: the oldest are dropped first.
    public var droppedForBudget: [UUID]
    /// Contain a personal identifier: never sent, and marked in the editor.
    public var skippedForPersonalData: [UUID]
    public var memoryTokens: Int
    public var memoryBudget: Int
}

/// Builds a `GenerationRequest` from a profile, the input and the target model
/// (ARCHITECTURE §4.4).
///
/// Rules come from versioned texts (`prompts.json`). Base rules are always present —
/// except where a setting overrides their subject: "keep the language" only without a
/// target language, "keep tú or usted" only with `register: keep`, "keep names,
/// numbers…" only for what `preserve` lists, "return it unchanged if fine" only when
/// the length and language are kept. Settings that are inert under `spellingOnly` are
/// left out. The input always travels as its own message, declared as data.
public struct PromptComposer: Sendable {
    struct Texts: Decodable, Sendable {
        struct LanguageTexts: Decodable, Sendable {
            let rules: [String: String]
            let guidanceHeader: String
        }
        struct Strategy: Decodable, Sendable {
            let version: Int
            let languages: [String: LanguageTexts]
        }
        let schemaVersion: Int
        let opposites: [[String]]
        let preservedNames: [String: [String: String]]
        let listConjunction: [String: String]
        let strategies: [String: Strategy]
        /// Introduces a one-off instruction typed in the picker. Outside the strategies on
        /// purpose: it never enters a profile's prompt, so adding it changed no prompt
        /// hash and no measured verdict.
        let instructionHeader: [String: String]?
    }

    /// The languages instructions are written in; any other input gets English.
    public static let instructionLanguages = ["en", "es"]

    /// The instruction language for an input: its own when it is Spanish or English —
    /// a small model answering Spanish text under English instructions drifts into
    /// English (measured, P1-T8) — English otherwise.
    public static func instructionLanguage(for input: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.spanish, .english]
        recognizer.processString(input)
        return recognizer.dominantLanguage == .spanish ? "es" : "en"
    }

    let texts: Texts

    public init() throws {
        texts = try RewriteResources.decode(Texts.self, from: "prompts")
        for strategy in PromptStrategy.allCases where texts.strategies[strategy.rawValue] == nil {
            throw RewriteResources.LoadError.unreadable("prompts", "missing strategy \(strategy.rawValue)")
        }
    }

    /// The version of a strategy's prompt texts; part of the prompt hash.
    public func version(of strategy: PromptStrategy) -> Int { strategyTexts(strategy).version }

    /// Pairs of rule ids that must never be emitted together.
    public var opposites: [(String, String)] {
        texts.opposites.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }

    private func strategyTexts(_ strategy: PromptStrategy) -> Texts.Strategy {
        texts.strategies[strategy.rawValue]!
    }

    private func languageTexts(_ strategy: PromptStrategy, _ language: String) -> Texts.LanguageTexts {
        let languages = strategyTexts(strategy).languages
        return languages[language] ?? languages["en"]!
    }

    // MARK: Rules

    /// The rule ids for a one-off instruction: only the rules no instruction should
    /// override — the input is data, who does what, nothing invented, the preserved
    /// items, the answer alone. The tone, length, register and language rules are left
    /// out, because the instruction is what decides them; keeping them would ask for
    /// two opposite things at once (conversational-agent contract §7).
    public func instructionRuleIDs(for settings: ProfileSettings) -> [String] {
        var ids = ["base.inputIsData", "scope.rewrite"]
        if !settings.preserve.isEmpty { ids.append("preserve") }
        ids += ["base.whoDidWhat", "base.noAdditions", "base.returnOnly"]
        return ids
    }

    /// The rule ids for `settings`, in prompt order.
    public func ruleIDs(for settings: ProfileSettings) -> [String] {
        let spellingOnly = settings.scope == .spellingOnly
        var ids = ["base.inputIsData", "scope.\(settings.scope.rawValue)"]
        ids.append(settings.targetLanguage == nil ? "language.keep" : "language.target")
        if settings.register == .keep { ids.append("register.keep") } else { ids.append("register.\(settings.register.rawValue)") }
        if !spellingOnly {
            ids.append("tone.\(settings.tone.rawValue)")
            ids.append("length.\(settings.length.rawValue)")
        }
        ids.append("abbreviations.\(settings.abbreviations.rawValue)")
        if !spellingOnly { ids.append("interjections.\(settings.interjections.rawValue)") }
        ids.append("emoji.\(settings.emoji.rawValue)")
        if !settings.preserve.isEmpty { ids.append("preserve") }
        ids += ["base.whoDidWhat", "base.noAdditions"]
        let keepsLength = spellingOnly || settings.length == .keep
        if keepsLength, settings.targetLanguage == nil { ids.append("base.unchangedIfFine") }
        ids.append("base.returnOnly")
        return ids
    }

    /// The rule texts for `settings` under `strategy`, with placeholders filled.
    public func rules(for settings: ProfileSettings, strategy: PromptStrategy, language: String = "en") -> [String] {
        rules(ids: ruleIDs(for: settings), settings: settings, strategy: strategy, language: language)
    }

    func rules(ids: [String], settings: ProfileSettings, strategy: PromptStrategy, language: String) -> [String] {
        let table = languageTexts(strategy, language).rules
        return ids.compactMap { id -> String? in
            guard var text = table[id] else { return nil }
            if id == "language.target", let code = settings.targetLanguage {
                text = text.replacingOccurrences(of: "{language}", with: Self.languageName(code, in: language))
            }
            if id == "preserve" {
                text = text.replacingOccurrences(of: "{list}", with: preservedList(settings.preserve, language: language))
            }
            return text
        }
    }

    func preservedList(_ preserve: Set<ProfileSettings.Preserved>, language: String = "en") -> String {
        let table = texts.preservedNames[language] ?? texts.preservedNames["en"] ?? [:]
        let names = preserve.sorted().map { table[$0.rawValue] ?? $0.rawValue }
        let conjunction = texts.listConjunction[language] ?? "and"
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " \(conjunction) " + names.last!
        }
    }

    static func languageName(_ code: String, in language: String = "en") -> String {
        Locale(identifier: language).localizedString(forIdentifier: code) ?? code
    }

    /// The instructions for a strategy: rules, then the guidance block when given, then
    /// the one-off instruction when there is one.
    func instructions(rules: [String], guidance: String?, strategy: PromptStrategy, language: String = "en",
                      instruction: String? = nil) -> String {
        var text = strategy == .compact
            ? rules.joined(separator: " ")
            : rules.map { "- \($0)" }.joined(separator: "\n")
        if let guidance, !guidance.isEmpty {
            text += "\n\n" + languageTexts(strategy, language).guidanceHeader + " " + guidance
        }
        if let instruction, !instruction.isEmpty {
            let header = texts.instructionHeader?[language] ?? texts.instructionHeader?["en"] ?? "The user asks for:"
            text += "\n\n" + header + " " + instruction
        }
        return text
    }

    // MARK: Composition

    /// Composes the request.
    ///
    /// - Parameters:
    ///   - contextTokens: the target model's context size, which picks the strategy.
    ///   - pinnedExample: the bench's `exampleBait` example — sent first, never evicted,
    ///     and left out of the prompt hash (BENCH §2.1).
    ///   - estimate: the token estimator of the pre-check (the provider's
    ///     `estimateTokens`); the default counts characters ÷ 3.5.
    ///   - instruction: what the user typed in the picker for this one rewrite. It
    ///     replaces the rules it would contradict (`instructionRuleIDs`) and is sent as
    ///     typed: the user wrote it for this text, now, so it is not screened like a
    ///     profile's stored guidance.
    public func compose(
        profile: Profile,
        input: String,
        model: ModelID,
        contextTokens: Int?,
        pinnedExample: Example? = nil,
        instruction: String? = nil,
        estimate: @Sendable (String) async -> Int = { Int((Double($0.count) / TokenEstimate.charactersPerToken).rounded(.up)) }
    ) async -> ComposedPrompt {
        let strategy = PromptStrategy.forContext(contextTokens)
        let budget = strategy.memoryBudgetTokens
        var used = 0

        // Guidance first: screened, cut for compact, counted.
        var guidanceStatus = CompositionReport.Guidance.none
        var guidanceSent: String?
        let trimmedGuidance = profile.guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGuidance.isEmpty {
            if !PersonalDataScreen.isClean(trimmedGuidance) {
                guidanceStatus = .skippedForPersonalData
            } else {
                let words = trimmedGuidance.split(whereSeparator: \.isWhitespace)
                if let limit = strategy.guidanceWordLimit, words.count > limit {
                    guidanceSent = words.prefix(limit).joined(separator: " ")
                    guidanceStatus = .truncated(words: limit)
                } else {
                    guidanceSent = trimmedGuidance
                    guidanceStatus = .sent
                }
                used += await estimate(guidanceSent!)
            }
        }

        // Then the pinned example, never evicted.
        var skipped: [UUID] = []
        var pinned: Example?
        if let pinnedExample {
            if PersonalDataScreen.isClean(pinnedExample.input + "\n" + pinnedExample.output) {
                pinned = pinnedExample
                used += await estimate(pinnedExample.input) + estimate(pinnedExample.output)
            } else {
                skipped.append(pinnedExample.id)
            }
        }

        // Then the profile's examples, newest first; what does not fit — the oldest —
        // is dropped (the newest correction is the most relevant).
        let chronological = profile.examples.enumerated()
            .sorted { ($0.element.addedAt, $0.offset) < ($1.element.addedAt, $1.offset) }
            .map(\.element)
        var kept: [Example] = []
        var dropped: [UUID] = []
        for example in chronological.reversed() {
            guard PersonalDataScreen.isClean(example.input + "\n" + example.output) else {
                skipped.append(example.id)
                continue
            }
            let cost = await estimate(example.input) + estimate(example.output)
            if used + cost <= budget {
                kept.append(example)
                used += cost
            } else {
                dropped.append(example.id)
            }
        }
        kept.reverse()

        // Examples in the input's language go last, right before it: the turn the model
        // just "answered" sets the language of the next one (measured, P1-T8).
        let language = Self.instructionLanguage(for: input)
        let ordered = kept.filter { Self.instructionLanguage(for: $0.input) != language }
            + kept.filter { Self.instructionLanguage(for: $0.input) == language }
        let sentExamples = (pinned.map { [$0] } ?? []) + ordered
        let typed = instruction?.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = typed?.isEmpty == false ? typed : nil
        let ruleIDs = instruction == nil ? ruleIDs(for: profile.settings) : instructionRuleIDs(for: profile.settings)
        let rules = rules(ids: ruleIDs, settings: profile.settings, strategy: strategy, language: language)
        let request = GenerationRequest(
            model: model,
            instructions: instructions(rules: rules, guidance: guidanceSent, strategy: strategy, language: language,
                                       instruction: instruction),
            input: input,
            examples: sentExamples.map { GenerationRequest.Example(input: $0.input, output: $0.output) },
            options: GenerationOptions(temperature: profile.temperature))

        return ComposedPrompt(
            request: request,
            strategy: strategy,
            promptHash: promptHash(profile: profile, strategy: strategy),
            report: CompositionReport(
                rules: ruleIDs,
                guidance: guidanceStatus,
                sentExamples: sentExamples.map(\.id),
                droppedForBudget: dropped.reversed(),
                skippedForPersonalData: skipped,
                memoryTokens: used,
                memoryBudget: budget))
    }

    // MARK: Hash

    /// SHA-256 over exactly: the strategy's prompt-text version, the strategy, the
    /// settings, the guidance, the profile's own examples (input and output, in order)
    /// and the temperature. Not the name or the symbol, and never a pinned example.
    public func promptHash(profile: Profile, strategy: PromptStrategy) -> String {
        struct Material: Encodable {
            let promptVersion: Int
            let strategy: PromptStrategy
            let settings: ProfileSettings
            let guidance: String
            let examples: [[String]]
            let temperature: Double?
        }
        let material = Material(
            promptVersion: version(of: strategy),
            strategy: strategy,
            settings: profile.settings,
            guidance: profile.guidance,
            examples: profile.examples.map { [$0.input, $0.output] },
            temperature: profile.temperature)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(material)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
