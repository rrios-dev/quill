import AppCore
import AppKit
import GlassUI
import QuillSupport
import SwiftUI

/// "A newer version is ready" (J-20): a card in the top-right corner, once per version,
/// because a dot on a small icon goes unseen for weeks. It never takes focus, leaves on
/// its own, and the badge and the menu item stay after it.
struct UpdateNoticeView: View {
    let version: String
    let install: () -> Void
    let later: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "update.notice.title \(QuillSupport.productName) \(version)", bundle: .localized))
                    .font(.system(size: 13, weight: .semibold))
                Text(String(localized: "update.notice.body", bundle: .localized))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            Spacer(minLength: 8)
            Button(String(localized: "update.notice.later", bundle: .localized), action: later)
                .controlSize(.regular)
            Button(String(localized: "update.notice.install", bundle: .localized), action: install)
                .controlSize(.regular)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }
}

@MainActor
final class UpdateNoticeController {
    /// Long enough to be read on returning to the desk, short enough not to linger.
    static let duration: Duration = .seconds(45)

    private var panel: PickerPanel?
    private var dismissal: Task<Void, Never>?

    var window: NSWindow? { panel }

    func show(version: String, install: @escaping () -> Void) {
        close()
        let view = UpdateNoticeView(version: version, install: { [weak self] in
            self?.close()
            install()
        }, later: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let panel = PickerPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.onCancel = { [weak self] in self?.close() }
        panel.contentView = Glass.makeWindowBackdrop(content: hosting, cornerRadius: 16)
        panel.setFrameOrigin(Self.origin(for: size))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        let text = String(localized: "update.notice.title \(QuillSupport.productName) \(version)", bundle: .localized)
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func close() {
        dismissal?.cancel()
        dismissal = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { panel.dismiss() } })
    }

    /// The top-right corner of the screen with the menu bar, where the system's own
    /// notifications arrive. Not under the menu-bar icon: menu-bar managers and the notch
    /// hide icons while still reporting a place for them.
    static func origin(for size: CGSize) -> NSPoint {
        let screen = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: screen.maxX - size.width - 12, y: screen.maxY - size.height - 12)
    }
}
