import AppKit
import Testing

@testable import SelectionKit

/// The copied selection's formatting as Quill's markup (U11, J-26). The HTML fixtures have
/// the shapes each host puts on the pasteboard; the RTF is built the way Mail and Notes
/// write it. Real copies from the owner's apps replace them at the capture checkpoint.
@Suite("Rich text to markup")
@MainActor
struct RichTextTests {
    @Test("Gmail: bold, italic, a link and a bulleted list, line by line")
    func gmail() throws {
        let html = """
            <div dir="ltr">Hi <b>Marta</b>, here is <i>what we discussed</i>:<div><ul>\
            <li>the <a href="https://example.com/doc">document</a></li><li>the invoice</li></ul>\
            <div>Thanks</div></div></div>
            """
        let markup = try #require(RichText.markup(html: html))
        #expect(markup.contains("Hi **Marta**, here is *what we discussed*:"))
        #expect(markup.contains("- the [document](https://example.com/doc)"))
        #expect(markup.contains("- the invoice"))
        #expect(markup.hasSuffix("Thanks"))
    }

    @Test("Google Docs: bold from inline font-weight inside its normal-weight wrapper, and a numbered list")
    func googleDocs() throws {
        let html = """
            <meta charset="utf-8"><b style="font-weight:normal;" id="docs-internal-guid-1a2b">\
            <p dir="ltr"><span style="font-weight:400;">The </span><span style="font-weight:700;">migraci\u{F3}n</span> plan</p>\
            <ol><li dir="ltr"><p dir="ltr"><span style="font-weight:400;">Dump on Saturday</span></p></li>\
            <li dir="ltr"><p dir="ltr"><span style="font-weight:400;">Fallback replica</span></p></li></ol></b>
            """
        let markup = try #require(RichText.markup(html: html))
        #expect(markup.contains("The **migraci\u{F3}n** plan"), "accents survive, and the wrapper's normal weight is not bold")
        #expect(!markup.contains("**The"))
        #expect(markup.contains("1. Dump on Saturday"))
        #expect(markup.contains("2. Fallback replica"))
    }

    @Test("Teams and Notion: strong and em in paragraphs, a nested list")
    func teamsAndNotion() throws {
        let html = """
            <p>Team, <strong>important</strong>: the deploy is <em>tomorrow</em>.</p>\
            <ul><li>Backend<ul><li>migration</li></ul></li><li>Frontend</li></ul>
            """
        let markup = try #require(RichText.markup(html: html))
        #expect(markup.contains("Team, **important**: the deploy is *tomorrow*."))
        #expect(markup.contains("- Backend"))
        #expect(markup.contains("  - migration"), "a nested item is indented one level")
        #expect(markup.contains("- Frontend"))
    }

    @Test("Mail and Notes: RTF with bold, a bulleted list and a line break kept exactly")
    func rtf() throws {
        let bold = NSFont.boldSystemFont(ofSize: 13), regular = NSFont.systemFont(ofSize: 13)
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Hi, ", attributes: [.font: regular]))
        text.append(NSAttributedString(string: "Juan", attributes: [.font: bold]))
        text.append(NSAttributedString(string: "\nsecond line\n", attributes: [.font: regular]))
        let style = NSMutableParagraphStyle()
        style.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        text.append(NSAttributedString(string: "\t\u{2022}\tone\n\t\u{2022}\ttwo", attributes: [.font: regular, .paragraphStyle: style]))
        let rtf = try #require(text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:]))

        let markup = try #require(RichText.markup(rtf: rtf))
        #expect(markup == "Hi, **Juan**\nsecond line\n- one\n- two")
    }

    @Test("literal asterisks and brackets are escaped, so they are not read as markup")
    func escaping() {
        #expect(RichText.escape("2*3 [note]") == #"2\*3 \[note\]"#)
        #expect(RichText.escape("maps__Route__c") == "maps__Route__c", "underscores are not markup here")
    }

    @Test("list markers AppKit writes into the text are recognised")
    func markers() {
        #expect(RichText.markerLength("\t\u{2022}\tone") == 3)
        #expect(RichText.markerLength("\t12.\ttwelve") == 5)
        #expect(RichText.markerLength("\t1\tone") == 3, "AppKit's ordered marker has no dot")
        #expect(RichText.markerLength("no marker") == 0)
    }

    // MARK: Markup back to rich text (paste)

    static let sample = "Team, **important**: the deploy is *tomorrow*.\n- Backend\n  - [migration](https://example.com/m)\n- Frontend\n1. first\n2. second\nThanks"

    @Test("markup survives the trip to RTF and back, line for line")
    func roundTripRTF() throws {
        let attributed = RichText.attributed(fromMarkup: Self.sample)
        let rtf = try #require(attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]))
        #expect(RichText.markup(rtf: rtf) == Self.sample)
    }

    @Test("the HTML for web apps is semantic: b, i, a, nested ul and ol")
    func html() {
        let html = RichText.html(fromMarkup: Self.sample)
        #expect(html.contains("<b>important</b>"))
        #expect(html.contains("<i>tomorrow</i>"))
        #expect(html.contains("<ul><li>Backend<ul><li><a href=\"https://example.com/m\">migration</a></li></ul></li><li>Frontend</li></ul>"))
        #expect(html.contains("<ol><li>first</li><li>second</li></ol>"))
        #expect(html.hasSuffix("Thanks"))
    }

    @Test("the HTML survives the trip back to markup")
    func roundTripHTML() throws {
        #expect(try #require(RichText.markup(html: RichText.html(fromMarkup: Self.sample))) == Self.sample)
    }

    @Test("plain text drops the markup and keeps bullets and numbers readable")
    func plain() {
        #expect(RichText.plainText(fromMarkup: Self.sample)
            == "Team, important: the deploy is tomorrow.\n\u{2022} Backend\n  \u{2022} migration\n\u{2022} Frontend\n1. first\n2. second\nThanks")
        #expect(RichText.verificationFragment(fromMarkup: "- **one** item") == "one item")
    }

    @Test("a link's own parentheses stay in its address")
    func parenthesesInLinks() throws {
        let markup = "See [the page](https://en.wikipedia.org/wiki/United_States_(disambiguation)) now"
        #expect(RichText.spans(markup) == [
            .init(text: "See "), .init(text: "the page", link: "https://en.wikipedia.org/wiki/United_States_(disambiguation)"),
            .init(text: " now"),
        ])
        #expect(try #require(RichText.markup(html: RichText.html(fromMarkup: markup))) == markup)
    }

    @Test("only web and mail links become links when pasted")
    func unsafeLinks() {
        let html = RichText.html(fromMarkup: "[click](javascript:alert(1)) and [mail](mailto:a@example.com)")
        #expect(!html.contains("javascript:"))
        #expect(html.contains("click"))
        #expect(html.contains("<a href=\"mailto:a@example.com\">mail</a>"))
        let attributed = RichText.attributed(fromMarkup: "[click](javascript:alert(1))")
        #expect(attributed.attribute(.link, at: 0, effectiveRange: nil) == nil)
    }

    @Test("escaped and unbalanced asterisks read as text")
    func spans() {
        #expect(RichText.spans(#"2\*3 and a * star"#).map(\.text).joined() == "2*3 and a * star")
        #expect(RichText.spans("**bold** and *it*") == [
            .init(text: "bold", bold: true), .init(text: " and "), .init(text: "it", italic: true),
        ])
    }

    @Test("the pasteboard item carries RTF, HTML and plain text, marked transient")
    func pasteboardItem() {
        let types = RichText.transientItem(markup: Self.sample).entries.map(\.type)
        #expect(types.first == NSPasteboard.PasteboardType.string.rawValue)
        #expect(types.contains(NSPasteboard.PasteboardType.rtf.rawValue))
        #expect(types.contains(NSPasteboard.PasteboardType.html.rawValue))
        #expect(types.contains(PasteboardMarkers.transient))
    }
}
