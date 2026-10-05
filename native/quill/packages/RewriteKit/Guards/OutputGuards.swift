import Foundation

/// Whether the captured selection carries formatting a plain-text replace would lose —
/// SelectionKit's three states, as RewriteKit sees them (G11).
public enum CaptureFormatting: String, Codable, Sendable {
    case rich, plain, unknown
}

/// Why a result needs the user's confirmation (⌘Return) before it can be applied.
public enum GuardFlag: Hashable, Sendable {
    /// G1: the first line looks like a preamble the closed list does not know.
    case uncertainPreamble(String)
    /// G2: `[…]`, `{{…}}` or `<…>` the input did not have.
    case inventedPlaceholder([String])
    /// G3: preserved names, numbers or links missing from the output.
    case missingPreserved(ProfileSettings.Preserved, [String])
    /// G3: a different number of interior line breaks.
    case lineBreaksChanged(input: Int, output: Int)
    /// G3: emoji dropped although the profile keeps them.
    case missingEmoji([String])
    /// G4: the output's language is not the input's (or not the target).
    case languageChanged(expected: String, found: String)
    /// G5: output/input word ratio outside the profile's band.
    case lengthOutOfBand(ratio: Double)
    /// G6.
    case addedGreeting
    /// G6.
    case addedSignOff
    /// G9: the output copies one of the examples instead of rewriting the input.
    case exampleEcho(UUID?)
    /// G11: rich formatting in the selection will be lost.
    case formattingWillBeLost
    /// G11: the app did not let Quill check the formatting.
    case formattingUnchecked
    /// G12: facts the input did not contain.
    case addedFacts([String])
    /// G13: a closing note from the model.
    case trailingCommentary(String)

    /// The guard that raised it.
    public var guardID: String {
        switch self {
        case .uncertainPreamble: "G1"
        case .inventedPlaceholder: "G2"
        case .missingPreserved, .lineBreaksChanged, .missingEmoji: "G3"
        case .languageChanged: "G4"
        case .lengthOutOfBand: "G5"
        case .addedGreeting, .addedSignOff: "G6"
        case .exampleEcho: "G9"
        case .formattingWillBeLost, .formattingUnchecked: "G11"
        case .addedFacts: "G12"
        case .trailingCommentary: "G13"
        }
    }
}

/// What the guards concluded about a result.
public enum GuardVerdict: Hashable, Sendable {
    /// A result to show; applying it needs ⌘Return when `flags` is not empty.
    case result(text: String, flags: [GuardFlag])
    /// G7: the output is the input.
    case noChanges
    /// G8: nothing left after G1.
    case empty
    /// G10: the model refused.
    case refused(text: String)
}

/// The deterministic checks run on every result (ARCHITECTURE §4.6). The model's
/// output is untrusted text: nothing here asks the model anything.
public struct OutputGuards: Sendable {
    /// What the guards need beyond the two texts.
    public struct Context: Sendable {
        public var settings: ProfileSettings
        /// The examples sent with the request (the profile's and any pinned one).
        public var examples: [Example]
        public var formatting: CaptureFormatting

        public init(settings: ProfileSettings, examples: [Example] = [], formatting: CaptureFormatting = .plain) {
            self.settings = settings
            self.examples = examples
            self.formatting = formatting
        }
    }

    /// The outcome, with what G1 removed (the bench counts dropped output).
    public struct Outcome: Hashable, Sendable {
        public var verdict: GuardVerdict
        /// The preamble line or wrapper G1 stripped, if any.
        public var stripped: String?
    }

    struct WordLists: Decodable, Sendable {
        let schemaVersion: Int
        let preambles: [String]
        let greetings: [String]
        let signOffs: [String]
        let refusals: [String]
        let commentary: [String]
        let interjections: [String]
        let stopwords: [String]
        let months: [String]
    }

    let lists: WordLists
    let abbreviations: AbbreviationTable
    private let months: Set<String>
    private let stopwords: Set<String>
    private let interjections: Set<String>

    public init() throws {
        lists = try RewriteResources.decode(WordLists.self, from: "guards")
        abbreviations = try AbbreviationTable.load()
        months = Set(lists.months)
        stopwords = Set(lists.stopwords)
        interjections = Set(lists.interjections)
    }

    /// Runs every guard. `input` is the text sent to the model, edge whitespace already
    /// trimmed (ARCHITECTURE §4.5); `output` is the model's answer as received.
    public func evaluate(input: String, output: String, context: Context) -> Outcome {
        let (cleaned, stripped, preambleFlag) = stripPreamble(output: output, input: input)
        let text = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // G8
        guard !text.isEmpty else { return Outcome(verdict: .empty, stripped: stripped) }
        // G10
        if isRefusal(text, input: input) { return Outcome(verdict: .refused(text: text), stripped: stripped) }
        // G7
        if Self.unified(text) == Self.unified(input) { return Outcome(verdict: .noChanges, stripped: stripped) }

        var flags: [GuardFlag] = []
        if let preambleFlag { flags.append(preambleFlag) }
        flags += placeholders(text, input: input)
        let language = Facts.language(of: input)
        flags += preserved(text, input: input, context: context, language: language.dominant)
        if let flag = languageFlag(text, input: input, settings: context.settings, inputLanguage: language) { flags.append(flag) }
        if let flag = lengthFlag(text, input: input, band: context.settings.lengthBand) { flags.append(flag) }
        flags += greetingsAndSignOffs(text, input: input)
        if let flag = exampleEcho(text, input: input, examples: context.examples) { flags.append(flag) }
        switch context.formatting {
        case .rich: flags.append(.formattingWillBeLost)
        case .unknown: flags.append(.formattingUnchecked)
        case .plain: break
        }
        if let flag = addedFacts(text, input: input, language: language.dominant) { flags.append(flag) }
        if let flag = trailingCommentary(text, input: input) { flags.append(flag) }
        return Outcome(verdict: .result(text: text, flags: flags), stripped: stripped)
    }

    // MARK: Normalisation

    func phrase(_ text: String) -> String {
        TextNormalizer.foldedPhrase(text, abbreviations: abbreviations)
    }

    /// `phrase` starts with `candidate` as whole words.
    static func startsWithPhrase(_ phrase: String, _ candidate: String) -> Bool {
        phrase == candidate || phrase.hasPrefix(candidate + " ")
    }

    static func containsPhrase(_ phrase: String, _ candidate: String) -> Bool {
        (" " + phrase + " ").contains(" " + candidate + " ")
    }

    /// G7's comparison: edge whitespace trimmed, line endings unified, typographic
    /// variants of quotes, apostrophes, spaces and ellipses unified — nothing else.
    static func unified(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for (from, to) in [("“", "\""), ("”", "\""), ("„", "\""), ("«", "\""), ("»", "\""), ("‘", "'"), ("’", "'"),
                           ("\u{00A0}", " "), ("\u{202F}", " "), ("…", "...")] {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: G1 — preamble strip

    func stripPreamble(output: String, input: String) -> (String, String?, GuardFlag?) {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped: String?
        let inputPhrase = phrase(input)

        if let newline = text.firstIndex(of: "\n") {
            let firstLine = String(text[..<newline]).trimmingCharacters(in: .whitespaces)
            if firstLine.hasSuffix(":") {
                let linePhrase = phrase(firstLine)
                let known = lists.preambles.contains { Self.startsWithPhrase(linePhrase, $0) }
                if known, !Self.containsPhrase(inputPhrase, linePhrase) {
                    stripped = firstLine
                    text = String(text[text.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if !known, !sharesContentWord(firstLine, with: input), !isGreetingLine(firstLine, input: input) {
                    return (unwrap(text, input: input), nil, .uncertainPreamble(firstLine))
                }
            }
        } else if let colon = text.firstIndex(of: ":") {
            // A single line "Texto corregido: <text>".
            let label = String(text[..<colon])
            let labelPhrase = phrase(label)
            if lists.preambles.contains(labelPhrase), !Self.containsPhrase(inputPhrase, labelPhrase) {
                stripped = label + ":"
                text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        let unwrapped = unwrap(text, input: input)
        if unwrapped != text, stripped == nil { stripped = String(text.prefix(1)) }
        return (unwrapped, stripped, nil)
    }

    /// Removes wrapping quotes, backticks or a code fence, unless the input was wrapped
    /// the same way.
    func unwrap(_ text: String, input: String) -> String {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6, !trimmedInput.hasPrefix("```") {
            var inner = String(text.dropFirst(3).dropLast(3))
            if let newline = inner.firstIndex(of: "\n"), !inner[..<newline].contains(" ") {
                inner = String(inner[inner.index(after: newline)...])   // the fence's language tag
            }
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (open, close) in [("\"", "\""), ("“", "”"), ("«", "»"), ("'", "'"), ("`", "`")] {
            if text.hasPrefix(open), text.hasSuffix(close), text.count > open.count + close.count,
               !(trimmedInput.hasPrefix(open) && trimmedInput.hasSuffix(close)) {
                let inner = String(text.dropFirst(open.count).dropLast(close.count))
                // Not a quote that merely opens and closes two different passages.
                if !inner.contains(open) || open != close {
                    return inner.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return text
    }

    func contentWords(_ text: String) -> Set<String> {
        Set(TextNormalizer.folded(text, abbreviations: abbreviations).filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    func sharesContentWord(_ line: String, with input: String) -> Bool {
        !contentWords(line).isDisjoint(with: contentWords(input))
    }

    /// A greeting line ("Hola, Juan:", "Estimado Juan:") replacing a greeting the input
    /// opened with is a corrected greeting, not a preamble.
    func isGreetingLine(_ line: String, input: String) -> Bool {
        let linePhrase = phrase(line)
        let inputPhrase = phrase(input)
        return lists.greetings.contains { Self.startsWithPhrase(linePhrase, $0) }
            && lists.greetings.contains { Self.startsWithPhrase(inputPhrase, $0) }
    }

    // MARK: G10 — refusal

    func isRefusal(_ text: String, input: String) -> Bool {
        let textPhrase = phrase(text)
        guard lists.refusals.contains(where: { Self.containsPhrase(textPhrase, $0) }) else { return false }
        return Similarity.folded(text, input, abbreviations: abbreviations) < 0.3
    }

    // MARK: G2 — invented placeholders

    func placeholders(_ text: String, input: String) -> [GuardFlag] {
        let pattern = #"\[[^\[\]\n]{1,40}\]|\{\{[^{}\n]{1,40}\}\}|<[^<>\n]{1,40}>"#
        // A link or address the input already had, wrapped in brackets ("<https://…>"), is
        // not a placeholder: only bracketed content the input lacks is invented.
        let invented = Facts.matches(pattern, in: text).map { String(text[$0]) }.filter { token in
            !input.contains(token) && !input.contains(String(token.dropFirst().dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "{}")))
        }
        return invented.isEmpty ? [] : [.inventedPlaceholder(invented)]
    }

    // MARK: G3 — preserved categories

    func preserved(_ text: String, input: String, context: Context, language: String?) -> [GuardFlag] {
        var flags: [GuardFlag] = []
        let preserve = context.settings.preserve
        let inputFacts = Facts.extract(from: input, languageCode: language, months: months)
        let outputFacts = Facts.extract(from: text, languageCode: language, months: months)

        if preserve.contains(.links) {
            let missingLinks = inputFacts.links.filter { link in !outputFacts.links.contains(link) && !text.contains(link) }
            let missingMentions = inputFacts.mentions.subtracting(outputFacts.mentions)
            let missing = (Array(missingLinks) + Array(missingMentions)).sorted()
            if !missing.isEmpty { flags.append(.missingPreserved(.links, missing)) }
        }
        if preserve.contains(.numbers) {
            var available = outputFacts.numbers
            var missing: [String] = []
            for value in inputFacts.numbers {
                if let index = available.firstIndex(of: value) { available.remove(at: index) } else {
                    missing.append(inputFacts.numberTexts[value] ?? "\(value)")
                }
            }
            for date in inputFacts.dates where !outputFacts.dates.contains(date) {
                missing.append(inputFacts.dateTexts[date] ?? "date")
            }
            if !missing.isEmpty { flags.append(.missingPreserved(.numbers, missing)) }
        }
        if preserve.contains(.names) {
            let removable = context.settings.interjections == .remove ? interjections : []
            let outputWords = Set(TextNormalizer.folded(text, abbreviations: nil))
            let missing = Facts.names(in: input, excluding: removable).filter { name in
                !outputWords.contains(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
            }
            if !missing.isEmpty { flags.append(.missingPreserved(.names, missing)) }
        }
        if preserve.contains(.lineBreaks) {
            let inputBreaks = Self.interiorLineBreaks(input)
            let outputBreaks = Self.interiorLineBreaks(text)
            if inputBreaks != outputBreaks { flags.append(.lineBreaksChanged(input: inputBreaks, output: outputBreaks)) }
        }
        if context.settings.emoji == .keep {
            let missing = inputFacts.emoji.subtracting(outputFacts.emoji).map(String.init).sorted()
            if !missing.isEmpty { flags.append(.missingEmoji(missing)) }
        }
        return flags
    }

    static func interiorLineBreaks(_ text: String) -> Int {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0 == "\n" }.count
    }

    // MARK: G4 — language

    func languageFlag(_ text: String, input: String, settings: ProfileSettings,
                      inputLanguage: (dominant: String?, likely: [String])) -> GuardFlag? {
        guard text.count >= 40, input.count >= 40, let found = Facts.language(of: text).dominant else { return nil }
        func base(_ code: String) -> String { String(code.prefix { $0 != "-" && $0 != "_" }) }
        if let target = settings.targetLanguage {
            return base(found) == base(target) ? nil : .languageChanged(expected: target, found: found)
        }
        guard !inputLanguage.likely.isEmpty else { return nil }
        return inputLanguage.likely.map(base).contains(base(found))
            ? nil : .languageChanged(expected: inputLanguage.dominant ?? inputLanguage.likely[0], found: found)
    }

    // MARK: G5 — length band

    func lengthFlag(_ text: String, input: String, band: ProfileSettings.LengthBand) -> GuardFlag? {
        let inputWords = TextNormalizer.words(input).count
        guard inputWords >= 6 else { return nil }
        let ratio = Double(TextNormalizer.words(text).count) / Double(inputWords)
        return band.contains(ratio) ? nil : .lengthOutOfBand(ratio: ratio)
    }

    // MARK: G6 — added greeting or sign-off

    func greetingsAndSignOffs(_ text: String, input: String) -> [GuardFlag] {
        var flags: [GuardFlag] = []
        let textPhrase = phrase(text)
        let inputPhrase = phrase(input)
        let opensWithGreeting = { (phrase: String) in self.lists.greetings.contains { Self.startsWithPhrase(phrase, $0) } }
        if opensWithGreeting(textPhrase), !opensWithGreeting(inputPhrase) { flags.append(.addedGreeting) }

        let lastLine = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text
        let lastSentence = Self.lastSentence(of: lastLine)
        let endPhrase = phrase(lastSentence)
        if let signOff = lists.signOffs.first(where: { Self.startsWithPhrase(endPhrase, $0) }),
           endPhrase.split(separator: " ").count <= signOff.split(separator: " ").count + 3,
           !Self.containsPhrase(inputPhrase, signOff) {
            flags.append(.addedSignOff)
        }
        return flags
    }

    static func lastSentence(of line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let body = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".!?…,; "))
        guard let index = body.lastIndex(where: { ".!?".contains($0) }) else { return trimmed }
        return String(body[body.index(after: index)...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: G9 — example echo

    func exampleEcho(_ text: String, input: String, examples: [Example]) -> GuardFlag? {
        for example in examples where Similarity.folded(example.input, input, abbreviations: abbreviations) < 0.8 {
            let toExample = Similarity.folded(text, example.output, abbreviations: abbreviations)
            let toInput = Similarity.folded(text, input, abbreviations: abbreviations)
            if toExample >= 0.9, toExample >= toInput + 0.2 { return .exampleEcho(example.id) }
        }
        return nil
    }

    // MARK: G12 — added facts

    func addedFacts(_ text: String, input: String, language: String?) -> GuardFlag? {
        let inputFacts = Facts.extract(from: input, languageCode: language, months: months)
        let outputFacts = Facts.extract(from: text, languageCode: language, months: months)
        var added: [String] = []
        var available = inputFacts.numbers
        for value in outputFacts.numbers {
            if let index = available.firstIndex(of: value) { available.remove(at: index) } else {
                added.append(outputFacts.numberTexts[value] ?? "\(value)")
            }
        }
        for date in outputFacts.dates where !inputFacts.dates.contains(date) {
            added.append(outputFacts.dateTexts[date] ?? "date")
        }
        added += outputFacts.links.subtracting(inputFacts.links).filter { !input.contains($0) }.sorted()
        added += outputFacts.mentions.subtracting(inputFacts.mentions).sorted()
        added += outputFacts.emails.subtracting(inputFacts.emails).sorted()
        return added.isEmpty ? nil : .addedFacts(added)
    }

    // MARK: G13 — trailing commentary

    func trailingCommentary(_ text: String, input: String) -> GuardFlag? {
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard paragraphs.count >= 2 || TextNormalizer.words(text).count > 6, let last = paragraphs.last else { return nil }
        let candidates = paragraphs.count >= 2 ? [last] : [Self.lastSentence(of: last)]
        let inputPhrase = phrase(input)
        for candidate in candidates {
            let candidatePhrase = phrase(candidate)
            if let match = lists.commentary.first(where: { Self.startsWithPhrase(candidatePhrase, $0) }),
               !Self.containsPhrase(inputPhrase, match) {
                return .trailingCommentary(candidate)
            }
        }
        return nil
    }
}
