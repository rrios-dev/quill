import AppKit

/// The picker's window: a borderless, **non-activating** panel that can become key —
/// the pattern Ámbar ships in `AmbarPanel` (ARCHITECTURE §5.1).
///
/// Non-activating, so the host app stays active and keeps its selection; key-capable,
/// so the picker still takes the keyboard. A `.borderless` window answers `false` to
/// `canBecomeKey` by default, and nothing typed would reach it.
final class PickerPanel: NSPanel {
    /// Esc, ⌘W, ⌘. — an explicit close the user asked for.
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        // Ámbar's four flags. Without `.canJoinAllApplications`, opening the panel over
        // another app's full-screen space pulls the user out of it (Ámbar's
        // PanelController records that failure); `.canJoinAllSpaces` and
        // `.fullScreenAuxiliary` cover the other cases, and `.transient` keeps it out of
        // Exposé and window cycling.
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .canJoinAllApplications,
        ]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Ordered **out**, never alpha-hidden: a hidden panel keeps key status and swallows
    /// the ⌘V meant for the host (ARCHITECTURE §3.2 step 2).
    func dismiss() {
        orderOut(nil)
    }
}
