import AppKit
import GlassUI
import RemoteTyping
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
    /// With `remote`, the line says after the outcome why the text stayed on this Mac while
    /// Batuta has the keyboard elsewhere (shared-control S6 R2).
    static func text(for outcome: AppliedOutcome, profile: String, direct: Bool, remote: RemoteRefusal? = nil) -> String {
        let line = text(for: outcome, profile: profile, direct: direct)
        guard let remote else { return line }
        return line + " — " + notice(remote)
    }

    /// Why the text stayed on this Mac, in Quill's words: Batuta's own sentence is English
    /// and written for agents.
    static func notice(_ refusal: RemoteRefusal) -> String {
        switch refusal {
        case .accessOff: PickerCopy.string("toast.remote.accessOff")
        case .refused: PickerCopy.string("toast.remote.refused")
        case .untrustedServer: PickerCopy.string("toast.remote.untrustedServer")
        case .noAnswer: PickerCopy.string("toast.remote.noAnswer")
        case .cannotType(let computer): PickerCopy.string("toast.remote.cannotType \(computer)")
        case .focusMoved(let computer): PickerCopy.string("toast.remote.focusMoved \(computer)")
        }
    }

    /// Why the shortcut did nothing while Batuta had the keyboard on another computer: that
    /// computer's selection could not be used (shared-control S6 R6). Said on its own.
    static func selectionNotice(_ notice: RemoteLanding.SelectionNotice) -> String {
        switch notice {
        case .nothingSelected(let computer): PickerCopy.string("toast.selection.nothingSelected \(computer)")
        case .unreadable(let computer): PickerCopy.string("toast.selection.unreadable \(computer)")
        case .refused(let refusal):
            switch refusal {
            case .accessOff: PickerCopy.string("toast.selection.accessOff")
            case .refused: PickerCopy.string("toast.selection.refused")
            case .untrustedServer: PickerCopy.string("toast.selection.untrustedServer")
            case .noAnswer: PickerCopy.string("toast.selection.noAnswer")
            case .cannotType(let computer): PickerCopy.string("toast.selection.unreadable \(computer)")
            case .focusMoved(let computer): PickerCopy.string("toast.selection.focusMoved \(computer)")
            }
        }
    }

    private static func text(for outcome: AppliedOutcome, profile: String, direct: Bool) -> String {
        switch outcome {
        case .typed(let computer):
            return PickerCopy.string("toast.typedOn \(computer)")
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
