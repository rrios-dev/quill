import AppKit
import Testing

@testable import SelectionKit

@Suite("Rich-format detection")
struct FormattingDetectorTests {
    // MARK: Accessibility attribute runs

    @Test("one font throughout is plain")
    func singleFont() {
        let runs = [AttributeRun(fontName: "Helvetica"), AttributeRun(fontName: "Helvetica")]
        #expect(FormattingDetector.state(of: runs) == .plain)
    }

    @Test("a bold, italic or oblique face is rich, whatever the case")
    func styledFace() {
        #expect(FormattingDetector.state(of: [AttributeRun(fontName: "Helvetica-Bold")]) == .rich)
        #expect(FormattingDetector.state(of: [AttributeRun(fontName: "Georgia-Italic")]) == .rich)
        #expect(FormattingDetector.state(of: [AttributeRun(fontName: "Helvetica-Oblique")]) == .rich)
        #expect(FormattingDetector.state(of: [AttributeRun(fontName: ".SFNS-Semibold")]) == .rich)
    }

    @Test("two different fonts are rich")
    func differentFonts() {
        let runs = [AttributeRun(fontName: "Helvetica"), AttributeRun(fontName: "Menlo-Regular")]
        #expect(FormattingDetector.state(of: runs) == .rich)
    }

    @Test("an emoji's fallback font is not a change of style")
    func emojiFallback() {
        let runs = [
            AttributeRun(fontName: "Helvetica"),
            AttributeRun(fontName: "AppleColorEmoji"),
            AttributeRun(fontName: "Helvetica"),
        ]
        #expect(FormattingDetector.state(of: runs) == .plain)
    }

    @Test("underline, links and list items are rich")
    func otherAttributes() {
        #expect(FormattingDetector.state(of: [AttributeRun(fontName: "Helvetica", underline: 1)]) == .rich)
        #expect(FormattingDetector.state(of: [AttributeRun(fontName: "Helvetica", hasLink: true)]) == .rich)
        #expect(FormattingDetector.state(of: [AttributeRun(fontName: "Helvetica", hasListItemPrefix: true)]) == .rich)
        #expect(FormattingDetector.state(of: [AttributeRun(fontName: "Helvetica", underline: 0)]) == .plain)
    }

    @Test("no runs means the app did not answer: unknown, never plain")
    func noRuns() {
        #expect(FormattingDetector.state(of: []) == .unknown)
    }

    @Test("runs are read from accessibility attribute keys")
    func readsAccessibilityKeys() {
        let run = LiveAccessibilityClient.run(from: [
            NSAttributedString.Key("AXFont"): ["AXFontName": "Helvetica-Bold", "AXFontSize": 13] as [String: Any],
            NSAttributedString.Key("AXUnderline"): NSNumber(value: 1),
        ])
        #expect(run == AttributeRun(fontName: "Helvetica-Bold", underline: 1))
    }

    // MARK: HTML (⌘C fallback)

    @Test("plain HTML from Chromium is plain")
    func plainHTML() {
        let html = #"<meta charset="utf-8"><span style="color: rgb(0, 0, 0); font-size: 14px;">Hello there</span>"#
        #expect(FormattingDetector.state(html: html) == .plain)
    }

    @Test("formatting elements are rich")
    func formattingElements() {
        for tag in ["b", "strong", "i", "em", "u", "li"] {
            #expect(FormattingDetector.state(html: "<p>Some <\(tag)>text</\(tag)></p>") == .rich, "\(tag)")
        }
        #expect(FormattingDetector.state(html: #"<a href="https://example.com">link</a>"#) == .rich)
        #expect(FormattingDetector.state(html: "<br><p>text</p>") == .plain)
    }

    @Test("inline bold, italic and decoration styles are rich")
    func inlineStyles() {
        #expect(FormattingDetector.state(html: #"<span style="font-weight:700">x</span>"#) == .rich)
        #expect(FormattingDetector.state(html: #"<span style="font-weight: bold;">x</span>"#) == .rich)
        #expect(FormattingDetector.state(html: #"<span style='font-style: italic'>x</span>"#) == .rich)
        #expect(FormattingDetector.state(html: #"<span style="text-decoration: underline">x</span>"#) == .rich)
        #expect(FormattingDetector.state(html: #"<span style="font-weight:400;text-decoration:none">x</span>"#) == .plain)
    }

    @Test("Google Docs' bold wrapper is not bold")
    func googleDocsWrapper() {
        let html = #"<meta charset="utf-8"><b style="font-weight:normal;" id="docs-internal-guid-1a2b3c"><span style="font-weight:400">plain text</span></b>"#
        #expect(FormattingDetector.state(html: html) == .plain)
        let bold = #"<b style="font-weight:normal;" id="docs-internal-guid-1a2b3c"><span style="font-weight:700">bold</span></b>"#
        #expect(FormattingDetector.state(html: bold) == .rich)
    }

    // MARK: RTF (⌘C fallback)

    private func rtf(_ text: NSAttributedString) throws -> Data {
        try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    @Test("plain RTF is plain; bold or underlined RTF is rich")
    func rtfRuns() throws {
        let font = try #require(NSFont(name: "Helvetica", size: 12))
        let plain = NSAttributedString(string: "plain words", attributes: [.font: font])
        #expect(FormattingDetector.state(rtf: try rtf(plain)) == .plain)

        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let mixed = NSMutableAttributedString(attributedString: plain)
        mixed.addAttribute(.font, value: bold, range: NSRange(location: 0, length: 5))
        #expect(FormattingDetector.state(rtf: try rtf(mixed)) == .rich)

        let underlined = NSMutableAttributedString(attributedString: plain)
        underlined.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: 5))
        #expect(FormattingDetector.state(rtf: try rtf(underlined)) == .rich)
    }

    @Test("data that is not RTF is unknown")
    func notRTF() {
        #expect(FormattingDetector.state(rtf: Data("not rtf at all".utf8)) == .unknown)
    }
}
