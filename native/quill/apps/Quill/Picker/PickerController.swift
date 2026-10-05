import AppKit
import GlassUI
import Observation
import QuillSupport
import SelectionKit
import SwiftUI

/// Owns the picker's panel for one session: shows it near the selection, routes the
/// keyboard to the session, resizes with the content, and closes it (ARCHITECTURE §5.1).
@MainActor
final class PickerController {
    private var panel: PickerPanel?
    private var hosting: NSHostingView<PickerView>?
    private var keyMonitor: Any?
    /// A resize is already queued: changes in the same frame are measured once.
    private var resizeQueued = false
    private let session: RewriteSession
    private let log = QuillLog(category: "picker")
    /// Called once the picker has closed, for the owner to drop the session.
    var onClosed: () -> Void = {}

    init(session: RewriteSession) {
        self.session = session
    }

    var isShown: Bool { panel?.isVisible == true }
    var isKey: Bool { panel?.isKeyWindow == true }
    var window: NSWindow? { panel }
    /// Sizes for the debug dump: the panel, the hosting view and what it asks for.
    var geometry: String {
        guard let panel, let hosting else { return "-" }
        return "panel \(panel.frame.size) hosting \(hosting.frame) fitting \(hosting.fittingSize) safe \(hosting.safeAreaInsets)"
    }

    func show() {
        guard panel == nil else { return }
        let view = PickerView(session: session, onOpenAccessibilitySettings: {
            NSWorkspace.shared.open(PermissionWatcher.settingsURL)
        })
        let hosting = NSHostingView(rootView: view)
        // The panel follows the content's size by hand (`resize`), keeping its top edge;
        // the hosting view only reports it.
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = Self.size(of: hosting)
        hosting.frame = NSRect(origin: .zero, size: size)
        let panel = PickerPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = Glass.makeWindowBackdrop(content: hosting, cornerRadius: Metrics.panelCornerRadius)
        panel.onCancel = { [weak self] in self?.forward(.escape) }
        panel.setFrameOrigin(origin(for: size))
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        self.hosting = hosting
        installKeyMonitor()
        trackContentSize()
    }

    /// Ordered out — never alpha-hidden: a hidden panel keeps key status and swallows
    /// the ⌘V meant for the host (ARCHITECTURE §3.2 step 2).
    func orderOut() {
        panel?.dismiss()
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.dismiss()
        panel = nil
        hosting = nil
        onClosed()
    }

    // MARK: Placement and size

    /// At the selection's bounds when the capture has them, else at the mouse; kept on
    /// the screen that holds the anchor (PickerPlacement, P2-T4).
    private func origin(for size: CGSize) -> CGPoint {
        let screens = NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) }
        return PickerPlacement.origin(panelSize: size, anchor: session.capture?.bounds,
                                      mouse: NSEvent.mouseLocation, screens: screens)
    }

    private static func size(of hosting: NSHostingView<PickerView>) -> CGSize {
        let fitting = hosting.fittingSize
        return CGSize(width: PickerView.width, height: max(64, min(fitting.height, 560)))
    }

    /// Re-measures whenever the session's visible state changes, keeping the top edge
    /// where it was so the picker grows downwards, away from the selection above it.
    /// A streamed answer changes the state on every token; those changes are coalesced
    /// into one measurement per frame instead of a layout pass per token.
    private func trackContentSize() {
        withObservationTracking {
            _ = session.state
            _ = session.showsDiff
            _ = session.profile
            _ = session.directApplyDeclined
            _ = session.instructionPending
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.panel != nil else { return }
                self.trackContentSize()
                self.queueResize()
            }
        }
    }

    private func queueResize() {
        guard !resizeQueued else { return }
        resizeQueued = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            self?.resizeQueued = false
            self?.resize()
        }
    }

    private func resize() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = Self.size(of: hosting)
        guard abs(size.height - panel.frame.height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true, animate: false)
        hosting.frame = NSRect(origin: .zero, size: size)
    }

    // MARK: Keys

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            let fieldSelection = (panel.firstResponder as? NSTextView).map { $0.selectedRange().length > 0 } ?? false
            guard let key = Self.key(for: event, correcting: self.isCorrecting,
                                     draftIsEmpty: self.session.instructionDraft.isEmpty,
                                     fieldHasSelection: fieldSelection) else { return event }
            self.forward(key)
            return nil
        }
    }

    private var isCorrecting: Bool {
        if case .correcting = session.state { return true }
        return false
    }

    private func forward(_ key: PickerKey) {
        let session = session
        Task { key == .returnKey ? await session.pressReturn() : await session.handle(key) }
    }

    /// The PRODUCT §4.1 keys. The instruction field has the keyboard, so plain letters
    /// are typing: the picker's own keys carry ⌘, except Return, Esc, Tab and the digits
    /// 1–9, which choose a profile while the field is empty. ⌘C copies the result unless
    /// the field has a selection of its own. While correcting, only ⌘Return and Esc
    /// belong to the session; everything else is typing (Return inserts a line break).
    static func key(for event: NSEvent, correcting: Bool, draftIsEmpty: Bool = true,
                    fieldHasSelection: Bool = false) -> PickerKey? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case 36, 76:
            if flags == .command { return .commandReturn }
            if correcting { return nil }
            if flags == .option { return .optionReturn }
            return flags.isEmpty ? .returnKey : nil
        case 53:
            return .escape
        default:
            break
        }
        if correcting { return nil }
        if Int(event.keyCode) == 48, flags.isEmpty { return .tab }
        let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            switch character {
            case "c": return fieldHasSelection ? nil : .commandC
            case "e": return .commandE
            case "d": return .d
            case "r": return .r
            default: return nil
            }
        }
        guard flags.isEmpty, draftIsEmpty else { return nil }
        if let digit = Int(character), (1...9).contains(digit) { return .number(digit) }
        return nil
    }
}
