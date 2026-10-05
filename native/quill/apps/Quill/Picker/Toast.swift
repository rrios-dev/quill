import AppKit
import GlassUI
import SelectionKit
import SwiftUI

/// The non-interactive confirmation after an apply (PRODUCT F2, §4.1 Applied): "Rewritten
/// with Work · ⌘Z to undo" after a direct apply, the outcome's line otherwise. Anything
/// that needs an action opens the picker instead, so the toast takes no input.
@MainActor
final class ToastController {
    static let duration: Duration = .seconds(2.2)

    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    func show(_ text: String, near anchor: CGRect?) {
        dismissal?.cancel()
        panel?.orderOut(nil)

        let hosting = NSHostingView(rootView: ToastView(text: text))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .canJoinAllApplications]
        panel.contentView = Glass.makeWindowBackdrop(content: hosting, cornerRadius: size.height / 2)
        let screens = NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) }
        panel.setFrameOrigin(PickerPlacement.origin(panelSize: size, anchor: anchor, mouse: NSEvent.mouseLocation, screens: screens))
        // Never key, never main: the host keeps the keyboard, and ⌘Z goes to it.
        panel.orderFrontRegardless()
        self.panel = panel
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])

        dismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
            self?.panel = nil
        }
    }

    /// The line for an outcome (PRODUCT §4.1 Applied).
    static func text(for outcome: AppliedOutcome, profile: String, direct: Bool) -> String {
        switch outcome {
        case .copied:
            return PickerCopy.string("toast.copied")
        case .replace(let replace):
            switch replace {
            case .replaced, .pasted:
                return direct ? PickerCopy.string("toast.rewrittenWith \(profile)") : Presentation.replaceOutcome(replace).text
            default:
                return Presentation.replaceOutcome(replace).text
            }
        }
    }
}

private struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, Metrics.Spacing.loose)
            .padding(.vertical, Metrics.Spacing.snug)
            .fixedSize()
    }
}
