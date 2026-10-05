import AppKit
import Foundation

/// Whether a selection carries formatting a plain-text replace would lose.
///
/// Three states, and `unknown` is never treated as plain: it means the app did not
/// let Quill check, which the result reports as its own flag (ARCHITECTURE §3.1 step 6,
/// guard G11).
public enum FormattingState: String, Codable, Sendable {
    case rich
    case plain
    case unknown
}

/// Detects rich formatting from what an app exposes (ARCHITECTURE §3.1 step 6).
public enum FormattingDetector {
    /// Fonts the system substitutes for glyphs the text's font lacks. A run in one of
    /// them is an emoji or a symbol, not a change of style.
    static let fallbackFonts: Set<String> = [
        "AppleColorEmoji", ".AppleColorEmojiUI", "AppleSymbols", "Apple Symbols",
        "LastResort", ".LastResort",
    ]

    /// From the selection's accessibility attribute runs.
    ///
    /// The accessibility font dictionary carries only name, family and size, so bold
    /// and italic are visible only in the font name. Rich when font names differ
    /// between runs or name a bold, italic or oblique face, or any run is underlined,
    /// linked or a list item. No runs at all is `unknown`: nothing was answered.
    public static func state(of runs: [AttributeRun]) -> FormattingState {
        guard !runs.isEmpty else { return .unknown }
        var fontNames = Set<String>()
        for run in runs {
            if run.underline != 0 || run.hasLink || run.hasListItemPrefix { return .rich }
            guard let name = run.fontName, !fallbackFonts.contains(name) else { continue }
            if isStyledFace(name) { return .rich }
            fontNames.insert(name)
        }
        return fontNames.count > 1 ? .rich : .plain
    }

    static func isStyledFace(_ fontName: String) -> Bool {
        let lowered = fontName.lowercased()
        return ["bold", "italic", "oblique"].contains { lowered.contains($0) }
    }

    /// From RTF on the pasteboard (the ⌘C fallback): bold, italic, underline or
    /// strikethrough runs, links, or list markers. Unparseable RTF is `unknown`.
    public static func state(rtf: Data) -> FormattingState {
        guard let text = try? NSAttributedString(
            data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil
        ) else { return .unknown }
        var rich = false
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, stop in
            if let font = attributes[.font] as? NSFont,
               !fallbackFonts.contains(font.fontName) {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) || traits.contains(.italic) { rich = true }
            }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0 { rich = true }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { rich = true }
            if attributes[.link] != nil { rich = true }
            if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle, !paragraph.textLists.isEmpty {
                rich = true
            }
            if rich { stop.pointee = true }
        }
        return rich ? .rich : .plain
    }

    /// From HTML on the pasteboard (the ⌘C fallback).
    ///
    /// Chromium puts HTML on the pasteboard even for plain text, so its presence proves
    /// nothing; only formatting elements and inline styles count. Google Docs wraps
    /// every copy in `<b style="font-weight:normal" id="docs-internal-guid-…">`, which
    /// is not bold and is ignored.
    public static func state(html: String) -> FormattingState {
        for tag in openingTags(in: html) {
            let isDocsWrapper = tag.name == "b" && tag.attributes.contains("docs-internal-guid-")
            if !isDocsWrapper, formattingElements.contains(tag.name) { return .rich }
            if let style = styleAttribute(of: tag.attributes), hasFormattingStyle(style) { return .rich }
        }
        return .plain
    }

    static let formattingElements: Set<String> = ["b", "strong", "i", "em", "u", "a", "li"]

    struct Tag {
        var name: String
        var attributes: String
    }

    static func openingTags(in html: String) -> [Tag] {
        let pattern = #"<([A-Za-z][A-Za-z0-9]*)\b([^>]*)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let name = Range(match.range(at: 1), in: html),
                  let attributes = Range(match.range(at: 2), in: html) else { return nil }
            return Tag(name: html[name].lowercased(), attributes: String(html[attributes]))
        }
    }

    static func styleAttribute(of attributes: String) -> String? {
        let pattern = #"style\s*=\s*("([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes))
        else { return nil }
        for group in [2, 3] {
            if let range = Range(match.range(at: group), in: attributes) { return String(attributes[range]) }
        }
        return nil
    }

    /// A bold `font-weight`, an italic `font-style`, or any `text-decoration` other than
    /// none.
    static func hasFormattingStyle(_ style: String) -> Bool {
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let property = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            switch property {
            case "font-weight":
                if value.hasPrefix("bold") { return true }
                if let weight = Int(value), weight >= 600 { return true }
            case "font-style":
                if value.hasPrefix("italic") || value.hasPrefix("oblique") { return true }
            case "text-decoration", "text-decoration-line":
                if value != "none", !value.isEmpty { return true }
            default:
                continue
            }
        }
        return false
    }
}
