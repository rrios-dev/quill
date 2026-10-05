#if DEBUG

import AppKit

/// Debug → Test fields (ARCHITECTURE §3.6): a plain field, a rich-text field and a
/// password field inside Quill itself, for the probe's native rows.
@MainActor
final class TestFieldsWindow {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "debug.fields.title", bundle: .localized)
        window.isReleasedWhenClosed = false

        let plain = NSTextField(string: "The quick brown fox jumps over the lazy dog.")
        plain.setAccessibilityIdentifier("quill.test.plain")

        let rich = NSTextView()
        rich.isRichText = true
        rich.setAccessibilityIdentifier("quill.test.rich")
        rich.textStorage?.setAttributedString(Self.richSample())
        let richScroll = NSScrollView()
        richScroll.documentView = rich
        richScroll.hasVerticalScroller = true
        richScroll.borderType = .bezelBorder
        rich.autoresizingMask = [.width]

        let secure = NSSecureTextField(string: "not-a-real-password")
        secure.setAccessibilityIdentifier("quill.test.password")

        let stack = NSStackView(views: [
            Self.label("debug.fields.plain"), plain,
            Self.label("debug.fields.rich"), richScroll,
            Self.label("debug.fields.password"), secure,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [plain, richScroll, secure] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        richScroll.heightAnchor.constraint(equalToConstant: 90).isActive = true
        rich.frame = NSRect(x: 0, y: 0, width: 420, height: 90)

        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    private static func label(_ key: String.LocalizationValue) -> NSTextField {
        let label = NSTextField(labelWithString: String(localized: key, bundle: .localized))
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        return label
    }

    private static func richSample() -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let text = NSMutableAttributedString(
            string: "Plain words, then bold words, then a link.",
            attributes: [.font: base]
        )
        let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        text.addAttribute(.font, value: bold, range: NSRange(location: 18, length: 10))
        text.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 37, length: 4))
        return text
    }
}

#endif
