import AppKit

/// The selection's formatting as a small markup the models read and write (PRODUCT U11,
/// quill J-26): `**bold**`, `*italic*`, `[text](url)`, list items as `- ` or `1. ` with two
/// spaces per level, and every line of the text as one line of markup, so line breaks
/// survive exactly. Headings, colours, fonts and tables are not carried: they read as
/// plain text.
///
/// The markup is Quill's own subset, not CommonMark: a single newline is a line break, and
/// nothing else in Markdown is interpreted. `RichText.attributed(from:)` (paste) reads it
/// back.
public enum RichText {
    /// The markup of what the host copied: RTF first (native apps), then HTML (browsers,
    /// Electron). Nil when neither parses or the copy carries no formatting worth keeping.
    @MainActor
    public static func markup(rtf: Data? = nil, html: String? = nil) -> String? {
        if let rtf, let text = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                       documentAttributes: nil) {
            return markup(from: text)
        }
        if let html, let text = attributed(html: html) {
            return markup(from: text)
        }
        return nil
    }

    /// HTML through AppKit's importer, which reads `b`, `strong`, inline `font-weight`
    /// (Google Docs), `a`, `ul`/`ol` and `p`. It needs the main thread.
    @MainActor
    static func attributed(html: String) -> NSAttributedString? {
        // Without a charset AppKit reads the bytes as Latin-1 and accents break.
        let document = html.lowercased().contains("<meta charset") ? html : "<meta charset=\"utf-8\">" + html
        return try? NSAttributedString(data: Data(document.utf8),
                                       options: [.documentType: NSAttributedString.DocumentType.html,
                                                 .characterEncoding: String.Encoding.utf8.rawValue],
                                       documentAttributes: nil)
    }

    // MARK: Attributed string → markup

    public static func markup(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        var lines: [String] = []
        var numbering: [ObjectIdentifier: Int] = [:]
        var location = 0
        while location <= string.length {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            var content = lineRange
            // Without the line's own terminator.
            while content.length > 0, let scalar = UnicodeScalar(string.character(at: content.upperBound - 1)),
                  CharacterSet.newlines.contains(scalar) {
                content.length -= 1
            }
            lines.append(line(text, range: content, numbering: &numbering))
            if lineRange.length == 0 || lineRange.upperBound >= string.length { break }
            location = lineRange.upperBound
        }
        // AppKit's importers end a document with a paragraph break the selection did not have.
        while lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func line(_ text: NSAttributedString, range: NSRange, numbering: inout [ObjectIdentifier: Int]) -> String {
        guard range.length > 0 else { return "" }
        let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        var prefix = ""
        var body = range
        if let lists = style?.textLists, let list = lists.last {
            // The importer writes the marker into the text ("\t•\t", "\t1.\t"): drop it.
            let raw = (text.string as NSString).substring(with: range)
            let skip = Self.markerLength(raw)
            if skip > 0, skip <= range.length { body = NSRange(location: range.location + skip, length: range.length - skip) }
            let indent = String(repeating: "  ", count: max(0, lists.count - 1))
            if list.isOrdered {
                let key = ObjectIdentifier(list)
                let number = (numbering[key] ?? list.startingItemNumber - 1) + 1
                numbering[key] = number
                prefix = indent + "\(number). "
            } else {
                prefix = indent + "- "
            }
        }
        return prefix + inline(text, range: body)
    }

    /// The length of a list marker AppKit put at the start of a list item: optional tabs,
    /// the bullet or number, then tabs or spaces.
    static func markerLength(_ line: String) -> Int {
        // A bullet, then tabs or spaces; a number or letter, with or without its dot, then tabs
        // (AppKit writes "\t1\t"), or with its dot then spaces.
        let pattern = #"^\t*(?:[•◦▪▫‣⁃●○■□–-][\t ]+|(?:\d+|[a-zA-Z])[.)]?\t+|(?:\d+|[a-zA-Z])[.)] +)"#
        guard let match = line.range(of: pattern, options: .regularExpression) else { return 0 }
        return line.utf16.distance(from: line.startIndex, to: match.upperBound)
    }

    /// Runs with the same bold, italic and link become one span; spaces at a span's edges
    /// stay outside its markers, or `** word**` would not read as bold.
    private static func inline(_ text: NSAttributedString, range: NSRange) -> String {
        var output = ""
        text.enumerateAttributes(in: range) { attributes, runRange, _ in
            let run = (text.string as NSString).substring(with: runRange)
            let font = attributes[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let bold = traits.contains(.bold) || (font.map(Self.isHeavy) ?? false)
            let italic = traits.contains(.italic) || ((attributes[.obliqueness] as? CGFloat) ?? 0) > 0
            let link = (attributes[.link] as? URL)?.absoluteString ?? (attributes[.link] as? String)
            output += span(run, bold: bold, italic: italic, link: link)
        }
        return merge(output)
    }

    private static func isHeavy(_ font: NSFont) -> Bool {
        let weight = (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
        return (weight ?? 0) >= NSFont.Weight.semibold.rawValue
    }

    private static func span(_ run: String, bold: Bool, italic: Bool, link: String?) -> String {
        let trimmed = run.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return run }
        let leading = String(run.prefix { $0 == " " || $0 == "\t" })
        let trailing = String(run.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
        var core = escape(trimmed)
        if let link { core = "[\(core)](\(link))" }
        if italic { core = "*\(core)*" }
        if bold { core = "**\(core)**" }
        return leading + core + trailing
    }

    /// `**a** **b**` written by two runs becomes `**a b**`.
    private static func merge(_ text: String) -> String {
        text.replacingOccurrences(of: "** **", with: " ").replacingOccurrences(of: "****", with: "")
    }

    /// Characters the markup reads are escaped in plain text, so a literal asterisk stays one.
    static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            // Only what this markup reads: `_` is not emphasis here (identifiers such as
            // `maps__Route__c` stay as they are).
            if "*[]\\".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}

extension NSTextList {
    var isOrdered: Bool {
        switch markerFormat {
        case .disc, .circle, .square, .hyphen, .box, .check, .diamond: false
        default: true
        }
    }
}

// MARK: - Markup → rich text (paste)

extension RichText {
    /// One line of markup: its list level and kind, and the inline text after the prefix.
    struct Line: Equatable {
        enum Kind: Equatable { case paragraph, bullet, number(Int) }
        var kind: Kind
        var level: Int
        var text: String
    }

    static func lines(of markup: String) -> [Line] {
        markup.components(separatedBy: "\n").map { raw in
            let spaces = raw.prefix { $0 == " " }.count
            let rest = raw.dropFirst(spaces)
            let level = spaces / 2 + 1
            if rest.hasPrefix("- ") || rest.hasPrefix("• ") {
                return Line(kind: .bullet, level: level, text: String(rest.dropFirst(2)))
            }
            if let match = rest.range(of: #"^\d+\. "#, options: .regularExpression),
               let number = Int(rest[match].dropLast(2)) {
                return Line(kind: .number(number), level: level, text: String(rest[match.upperBound...]))
            }
            return Line(kind: .paragraph, level: 0, text: raw)
        }
    }

    /// An inline span: text with its bold, italic and link.
    struct Span: Equatable {
        var text: String
        var bold = false
        var italic = false
        var link: String?
    }

    /// `**bold**`, `*italic*`, `[text](url)` and `\`-escapes; anything unbalanced reads as text.
    static func spans(_ text: String) -> [Span] {
        var spans: [Span] = []
        var bold = false, italic = false
        var buffer = ""
        let characters = Array(text)
        func flush(link: String? = nil) {
            if !buffer.isEmpty { spans.append(Span(text: buffer, bold: bold, italic: italic, link: link)) }
            buffer = ""
        }
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                buffer.append(characters[index + 1]); index += 2; continue
            }
            if character == "*", index + 1 < characters.count, characters[index + 1] == "*",
               bold || String(characters[(index + 2)...]).contains("**") {
                flush(); bold.toggle(); index += 2; continue
            }
            if character == "*", italic || String(characters[(index + 1)...]).contains("*") {
                flush(); italic.toggle(); index += 1; continue
            }
            if character == "[", let close = characters[index...].firstIndex(of: "]"),
               close + 1 < characters.count, characters[close + 1] == "(",
               let end = Self.closingParenthesis(characters, from: close + 1) {
                flush()
                buffer = String(characters[(index + 1)..<close])
                flush(link: String(characters[(close + 2)..<end]))
                index = end + 1; continue
            }
            buffer.append(character); index += 1
        }
        flush()
        return spans
    }

    /// The `)` that closes the `(` at `open`, counting nested pairs, so an address such as
    /// `…/United_States_(disambiguation)` keeps its own parentheses.
    static func closingParenthesis(_ characters: [Character], from open: Int) -> Int? {
        var depth = 0
        var index = open
        while index < characters.count {
            switch characters[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index += 1
        }
        return nil
    }

    /// Only these schemes become links on paste; any other (`javascript:`, `file:`) stays text.
    static func safeLink(_ link: String?) -> String? {
        guard let link, let scheme = URL(string: link)?.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return link
    }

    /// The text without markup: what a plain-text target receives, and what verification reads.
    public static func plainText(fromMarkup markup: String) -> String {
        lines(of: markup).map { line in
            let text = spans(line.text).map(\.text).joined()
            let indent = String(repeating: "  ", count: max(0, line.level - 1))
            switch line.kind {
            case .paragraph: return text
            case .bullet: return indent + "• " + text
            case .number(let number): return indent + "\(number). " + text
            }
        }
        .joined(separator: "\n")
    }

    /// The first line of a formatted result as plain text, without its list marker.
    public static func verificationFragment(fromMarkup markup: String) -> String {
        let first = lines(of: markup).first { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        return first.map { spans($0.text).map(\.text).joined().trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// The markup as an attributed string: bold and italic on the system font, links, and
    /// lists as AppKit's text lists, so RTF readers (Mail, Notes, Pages) see real lists.
    public static func attributed(fromMarkup markup: String, size: CGFloat = NSFont.systemFontSize) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let lines = lines(of: markup)
        var lists: [Int: NSTextList] = [:]
        for (offset, line) in lines.enumerated() {
            let style = NSMutableParagraphStyle()
            var marker = ""
            switch line.kind {
            case .paragraph:
                lists.removeAll()
            case .bullet, .number:
                let ordered: Bool = if case .number = line.kind { true } else { false }
                for level in 1...line.level where lists[level] == nil
                    || (level == line.level && (lists[level]!.markerFormat == .decimal) != ordered) {
                    lists[level] = NSTextList(markerFormat: level == line.level && ordered ? .decimal : .disc, options: 0)
                }
                lists = lists.filter { $0.key <= line.level }
                style.textLists = (1...line.level).compactMap { lists[$0] }
                let indent = CGFloat(line.level) * 24
                style.headIndent = indent
                style.firstLineHeadIndent = indent - 12
                if case .number(let number) = line.kind { marker = "\t\(number).\t" } else { marker = "\t•\t" }
            }
            let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: style]
            output.append(NSAttributedString(string: marker, attributes: base))
            for span in spans(line.text) {
                var attributes = base
                var traits: NSFontDescriptor.SymbolicTraits = []
                if span.bold { traits.insert(.bold) }
                if span.italic { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withSymbolicTraits(traits)
                    attributes[.font] = NSFont(descriptor: descriptor, size: size) ?? NSFont.boldSystemFont(ofSize: size)
                }
                if let link = safeLink(span.link), let url = URL(string: link) { attributes[.link] = url }
                output.append(NSAttributedString(string: span.text, attributes: attributes))
            }
            if offset < lines.count - 1 { output.append(NSAttributedString(string: "\n", attributes: base)) }
        }
        return output
    }

    /// Plain semantic HTML: what web apps (Gmail, Docs, Teams, Notion) paste best.
    public static func html(fromMarkup markup: String) -> String {
        func inline(_ text: String) -> String {
            spans(text).map { span in
                var html = span.text.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                if let link = safeLink(span.link) { html = "<a href=\"\(link.replacingOccurrences(of: "\"", with: "%22"))\">\(html)</a>" }
                if span.italic { html = "<i>\(html)</i>" }
                if span.bold { html = "<b>\(html)</b>" }
                return html
            }.joined()
        }
        var html = ""
        var open: [String] = []          // the list tags open, outermost first
        var previousWasParagraph = false
        for line in lines(of: markup) {
            switch line.kind {
            case .paragraph:
                while let tag = open.popLast() { html += "</li></\(tag)>" }
                if previousWasParagraph { html += "<br>" }
                html += inline(line.text)
                previousWasParagraph = true
            case .bullet, .number:
                let tag: String = if case .number = line.kind { "ol" } else { "ul" }
                if previousWasParagraph { html += "<br>"; previousWasParagraph = false }
                while open.count > line.level { html += "</li></\(open.removeLast())>" }
                if open.count == line.level, open.last != tag { html += "</li></\(open.removeLast())>" }
                if open.count == line.level { html += "</li>" }
                while open.count < line.level { open.append(tag); html += "<\(tag)>" }
                html += "<li>" + inline(line.text)
            }
        }
        while let tag = open.popLast() { html += "</li></\(tag)>" }
        return "<meta charset=\"utf-8\">" + html
    }

    /// The pasteboard item for a formatted result: RTF and HTML for rich targets, the plain
    /// text for the rest, marked transient like every write of Quill's.
    @MainActor
    public static func transientItem(markup: String) -> PasteboardItemData {
        let attributed = attributed(fromMarkup: markup)
        var entries: [PasteboardItemData.Entry] = []
        if let rtf = attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]) {
            entries.append(.init(type: NSPasteboard.PasteboardType.rtf.rawValue, data: rtf))
        }
        entries.append(.init(type: NSPasteboard.PasteboardType.html.rawValue, data: Data(html(fromMarkup: markup).utf8)))
        var plain = PasteboardMarkers.transientText(plainText(fromMarkup: markup)).entries
        entries.insert(contentsOf: plain.prefix(1), at: 0)
        plain.removeFirst()
        entries += plain
        return PasteboardItemData(entries: entries)
    }
}
