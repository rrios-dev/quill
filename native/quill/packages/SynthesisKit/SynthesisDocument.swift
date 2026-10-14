import Foundation

/// A synthesis read for display: the model's Markdown, cut into sections that each know
/// what they hold — decisions, tasks, risks, disagreements — so the window can draw each
/// kind as what it is instead of as lines of text.
///
/// The model writes Markdown (the prompt asks for `##` sections, `-` lists and tables
/// with a header row); this reads what it actually wrote, which also includes numbered
/// headings, `*` bullets and bold labels used as headings. Nothing here changes the text:
/// a section it cannot classify is a `topic`, drawn plainly.
public struct SynthesisDocument: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case decisions, tasks, risks, disagreements, insight, topic
    }

    public enum CalloutKind: Equatable, Sendable {
        case decision, task, risk, disagreement, context
    }

    public struct Table: Equatable, Sendable {
        public var header: [String]
        public var rows: [[String]]

        /// The column that names who does something, if the header has one.
        public var ownerColumn: Int? { column(matching: ["responsable", "owner", "quien", "who", "persona", "defendida", "person"]) }
        /// The column with a date or deadline, if the header has one.
        public var dateColumn: Int? { column(matching: ["fecha", "date", "plazo", "cuando", "when", "deadline"]) }

        private func column(matching keys: [String]) -> Int? {
            header.firstIndex { cell in keys.contains { SynthesisDocument.fold(cell).contains($0) } }
        }
    }

    public enum Block: Equatable, Sendable {
        case subheading(String)
        case list([String], ordered: Bool)
        case table(Table)
        case paragraph(String)
        /// A paragraph that opens with a bold label ("**Decisión:** …").
        case callout(CalloutKind, label: String, text: String)
    }

    public struct Section: Equatable, Sendable, Identifiable {
        public var id: Int
        public var title: String?
        public var kind: Kind
        public var blocks: [Block]

        /// How many things the section lists: its items, or the rows of its table.
        public var itemCount: Int {
            blocks.reduce(0) { total, block in
                switch block {
                case .list(let items, _): total + items.count
                case .table(let table): total + table.rows.count
                default: total
                }
            }
        }
    }

    public var title: String?
    public var sections: [Section]

    /// How many items each kind holds, across sections: the counts shown at the top.
    public func count(of kind: Kind) -> Int {
        sections.filter { $0.kind == kind }.reduce(0) { $0 + $1.itemCount }
    }

    public init(markdown: String) {
        var title: String?
        var sections: [Section] = []
        var current = Section(id: 0, title: nil, kind: .topic, blocks: [])
        var list: (items: [String], ordered: Bool)?
        var table: [[String]] = []
        var paragraph: [String] = []

        func flushInline() {
            if let pending = list {
                current.blocks.append(.list(pending.items, ordered: pending.ordered))
                list = nil
            }
            if !table.isEmpty {
                current.blocks.append(.table(Table(header: table[0], rows: Array(table.dropFirst()))))
                table = []
            }
            if !paragraph.isEmpty {
                current.blocks.append(Self.paragraphBlock(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }
        func startSection(_ heading: String) {
            flushInline()
            if current.title != nil || !current.blocks.isEmpty { sections.append(current) }
            current = Section(id: sections.count, title: heading, kind: Self.kind(of: heading), blocks: [])
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushInline()
                continue
            }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let text = Self.stripHeading(String(line.dropFirst(level)))
                if level == 1, title == nil, sections.isEmpty, current.blocks.isEmpty {
                    title = text
                } else if level <= 2 {
                    startSection(text)
                } else {
                    flushInline()
                    current.blocks.append(.subheading(text))
                }
                continue
            }
            if line.hasPrefix("|") {
                // Only one kind of block is ever pending, so this never cuts a table.
                if list != nil || !paragraph.isEmpty { flushInline() }
                if line.allSatisfy({ "|-: ".contains($0) }) { continue }
                var cells = line.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.first == "" { cells.removeFirst() }
                if cells.last == "" { cells.removeLast() }
                table.append(cells)
                continue
            }
            if let item = Self.listItem(line) {
                if !table.isEmpty || !paragraph.isEmpty { flushInline() }
                if list == nil || list?.ordered != item.ordered {
                    if let pending = list { current.blocks.append(.list(pending.items, ordered: pending.ordered)) }
                    list = ([], item.ordered)
                }
                list?.items.append(item.text)
                continue
            }
            // A continuation of a list item, indented under it.
            if raw.hasPrefix("  "), list != nil, var items = list?.items, !items.isEmpty {
                items[items.count - 1] += " " + line
                list?.items = items
                continue
            }
            if list != nil || !table.isEmpty { flushInline() }
            paragraph.append(line)
        }
        flushInline()
        if current.title != nil || !current.blocks.isEmpty { sections.append(current) }
        self.title = title
        self.sections = sections
    }

    // MARK: Reading

    static func kind(of heading: String) -> Kind {
        let key = fold(heading)
        if has(key, "desacuerdo", "disagree", "tension") { return .disagreements }
        if has(key, "riesgo", "risk", "abiert", "open") { return .risks }
        if has(key, "tarea", "task", "accion", "acciones", "action", "compromiso")
            || key.contains("next step") || key.contains("proximos pasos") { return .tasks }
        if has(key, "decisi", "acuerdo", "agreed") { return .decisions }
        if has(key, "lectura", "reading", "conclusi", "insight") { return .insight }
        return .topic
    }

    static func calloutKind(of label: String) -> CalloutKind {
        let key = fold(label)
        if has(key, "decisi", "acuerdo", "decided") { return .decision }
        if has(key, "riesgo", "risk") { return .risk }
        if has(key, "desacuerdo", "objecion", "objection", "postura", "disagree") { return .disagreement }
        if has(key, "compromiso", "tarea", "commitment", "task") { return .task }
        return .context
    }

    /// Whether a word of `key` starts with one of `prefixes`: "transacción" is not an
    /// action, "Tareas" is a task.
    static func has(_ key: String, _ prefixes: String...) -> Bool {
        let words = key.split { !$0.isLetter }
        return words.contains { word in prefixes.contains { word.hasPrefix($0) } }
    }

    /// "**Decisión (Yo):** text" → a callout; "**Opciones sobre la mesa**" → a subheading.
    static func paragraphBlock(_ text: String) -> Block {
        guard text.hasPrefix("**"),
              let close = text.range(of: "**", range: text.index(text.startIndex, offsetBy: 2)..<text.endIndex)
        else { return .paragraph(text) }
        var label = String(text[text.index(text.startIndex, offsetBy: 2)..<close.lowerBound])
        var rest = String(text[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix(":") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if label.hasSuffix(":") { label.removeLast() }
        label = label.trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return .subheading(label) }
        return .callout(calloutKind(of: label), label: label, text: rest)
    }

    static func listItem(_ line: String) -> (text: String, ordered: Bool)? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            return (String(line.dropFirst(marker.count)), false)
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 2 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return (String(rest.dropFirst(2)), true) }
        }
        return nil
    }

    /// "1. Migración" → "Migración"; "**Tareas**" → "Tareas".
    static func stripHeading(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("**"), text.hasSuffix("**"), text.count > 4 { text = String(text.dropFirst(2).dropLast(2)) }
        if let item = listItem(text), item.ordered { text = item.text }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
