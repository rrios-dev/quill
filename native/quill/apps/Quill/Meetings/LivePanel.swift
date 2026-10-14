import AppKit
import GlassUI
import MeetingKit
import SwiftUI

/// The live panel's window: floating, never activating, movable by dragging anywhere on
/// it, resizable from its edges, and able to shrink to a recording orb.
///
/// It was a fixed panel pinned to the top-right corner, which the owner could only show
/// or hide during a call (2026-10-08). A meeting is watched beside other windows, and
/// where it fits changes with each call.
final class LivePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow
        // The picker's flags (PickerPanel): over a full-screen call it must not pull the
        // user out of that space.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .canJoinAllApplications]
    }

    // Key only so its text can be selected and its buttons reached by keyboard; it never
    // activates Quill (`.nonactivatingPanel`), so the call keeps the focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class LivePanelController {
    enum Mode { case expanded, orb }

    static let minimumSize = NSSize(width: 360, height: 240)
    static let defaultSize = NSSize(width: 520, height: 440)
    static let orbSize: CGFloat = 64
    private static let frameKey = "meetings.live.frame"
    private static let orbKey = "meetings.live.orb"

    private var panel: LivePanel?
    private(set) var mode: Mode = .expanded
    private let coordinator: MeetingsCoordinator
    private let app: MeetingApp

    init(coordinator: MeetingsCoordinator, app: MeetingApp) {
        self.coordinator = coordinator
        self.app = app
    }

    var window: NSWindow? { panel }

    func show(mode: Mode = .expanded) {
        let panel = self.panel ?? LivePanel(contentRect: NSRect(origin: .zero, size: Self.defaultSize))
        self.panel = panel
        apply(mode, to: panel, animated: false)
        panel.orderFrontRegardless()
    }

    func close() {
        remember()
        panel?.orderOut(nil)
        panel = nil
    }

    func collapse() { set(.orb) }
    func expand() { set(.expanded) }

    private func set(_ mode: Mode) {
        guard let panel, mode != self.mode else { return }
        remember()
        apply(mode, to: panel, animated: true)
    }

    private func apply(_ mode: Mode, to panel: LivePanel, animated: Bool) {
        self.mode = mode
        let frame: NSRect
        let content: NSView
        switch mode {
        case .expanded:
            let hosting = NSHostingView(rootView: LiveView(coordinator: coordinator, app: app,
                                                          collapse: { [weak self] in self?.collapse() }))
            content = Glass.makeWindowBackdrop(content: hosting, cornerRadius: Metrics.panelCornerRadius)
            panel.styleMask.insert(.resizable)
            panel.contentMinSize = Self.minimumSize
            frame = Self.savedFrame(Self.frameKey) ?? Self.defaultFrame()
        case .orb:
            let hosting = NSHostingView(rootView: RecordingOrb(coordinator: coordinator, app: app,
                                                               expand: { [weak self] in self?.expand() }))
            content = Glass.makeWindowBackdrop(content: hosting, cornerRadius: Self.orbSize / 2)
            panel.styleMask.remove(.resizable)
            panel.contentMinSize = NSSize(width: Self.orbSize, height: Self.orbSize)
            let origin = Self.savedFrame(Self.orbKey)?.origin
                ?? NSPoint(x: panel.frame.maxX - Self.orbSize, y: panel.frame.maxY - Self.orbSize)
            frame = NSRect(origin: origin, size: NSSize(width: Self.orbSize, height: Self.orbSize))
        }
        content.autoresizingMask = [.width, .height]
        panel.contentView = content
        panel.setFrame(Self.onScreen(frame), display: true, animate: animated)
    }

    /// Each shape remembers where it was left, for this call and the next.
    private func remember() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: mode == .expanded ? Self.frameKey : Self.orbKey)
    }

    private static func savedFrame(_ key: String) -> NSRect? {
        guard let text = UserDefaults.standard.string(forKey: key) else { return nil }
        let rect = NSRectFromString(text)
        return rect.isEmpty ? nil : rect
    }

    private static func defaultFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: screen.maxX - defaultSize.width - 16, y: screen.maxY - defaultSize.height - 12,
                      width: defaultSize.width, height: defaultSize.height)
    }

    /// A frame saved on a display that is gone comes back onto the one in use.
    private static func onScreen(_ frame: NSRect) -> NSRect {
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return frame }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        return NSRect(x: screen.maxX - frame.width - 16, y: screen.maxY - frame.height - 12,
                      width: frame.width, height: frame.height)
    }
}

/// The panel folded away: a glass orb that says a meeting is being recorded and
/// transcribed, and who is speaking.
///
/// The red core breathes on its own — recording is never in doubt, even in silence.
/// Ripples leave it as people talk, as strong as their voices: orange for the others,
/// cyan for the user. A slow comet circles it while text keeps arriving. Click to open
/// the panel again; drag to move it anywhere.
struct RecordingOrb: View {
    let coordinator: MeetingsCoordinator
    let app: MeetingApp
    let expand: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ripples = RippleField()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let levels = coordinator.levels
            Canvas { canvas, size in
                ripples.update(time: time, others: levels.others, me: levels.me)
                draw(in: &canvas, size: size, time: time)
            }
        }
        .frame(width: LivePanelController.orbSize, height: LivePanelController.orbSize)
        .contentShape(Circle())
        .onTapGesture(perform: expand)
        .help(String(localized: "live.orb.help \(app.name)", bundle: .localized))
        .accessibilityElement()
        .accessibilityLabel(String(localized: "live.orb.label \(app.name)", bundle: .localized))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: MeetingCopy.t("live.orb.expand"), expand)
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, time: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let core: CGFloat = 9

        for ripple in ripples.live(at: time) {
            let radius = core + ripple.progress * (size.width / 2 - core - 1)
            let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            canvas.stroke(ring, with: .color(ripple.color.opacity(Double(ripple.strength) * (1 - ripple.progress) * 0.9)),
                          lineWidth: 1.5 + 2 * CGFloat(ripple.strength) * (1 - ripple.progress))
        }

        // The comet: transcription at work.
        let orbit = size.width / 2 - 5
        let angle = reduceMotion ? -Double.pi / 2 : time.truncatingRemainder(dividingBy: 2.4) / 2.4 * 2 * .pi
        var comet = Path()
        comet.addArc(center: center, radius: orbit, startAngle: .radians(angle - 1.1), endAngle: .radians(angle), clockwise: false)
        canvas.stroke(comet, with: .linearGradient(
            Gradient(colors: [.white.opacity(0), .white.opacity(0.75)]),
            startPoint: CGPoint(x: center.x + orbit * cos(angle - 1.1), y: center.y + orbit * sin(angle - 1.1)),
            endPoint: CGPoint(x: center.x + orbit * cos(angle), y: center.y + orbit * sin(angle))),
            style: StrokeStyle(lineWidth: 2, lineCap: .round))

        // The core breathes, a little faster and fuller when someone is speaking.
        let breath = reduceMotion ? 0.5 : (sin(time * 2.2) + 1) / 2
        let radius = core + CGFloat(breath) * 1.5 + CGFloat(ripples.loudness) * 3
        let glow = Path(ellipseIn: CGRect(x: center.x - radius * 1.9, y: center.y - radius * 1.9, width: radius * 3.8, height: radius * 3.8))
        canvas.fill(glow, with: .radialGradient(Gradient(colors: [.red.opacity(0.45), .red.opacity(0)]),
                                                center: center, startRadius: radius * 0.6, endRadius: radius * 1.9))
        canvas.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(.red))
    }
}

/// Ripples emitted by speech: a new one whenever a voice rises above a whisper, at most
/// every 0.35 s per channel, each living 1.6 s.
final class RippleField {
    struct Ripple {
        let born: Double
        let strength: Float
        let color: Color
        var progress: CGFloat = 0
    }

    private var ripples: [Ripple] = []
    private var lastEmitted: [Int: Double] = [:]
    private(set) var loudness: Float = 0
    private let life = 1.6

    func update(time: Double, others: Float, me: Float) {
        loudness = max(others, me)
        for (channel, level, color) in [(0, others, Color.orange), (1, me, Color.cyan)] where level > 0.35 {
            if time - (lastEmitted[channel] ?? 0) > 0.35 {
                ripples.append(Ripple(born: time, strength: level, color: color))
                lastEmitted[channel] = time
            }
        }
        ripples.removeAll { time - $0.born > life }
    }

    func live(at time: Double) -> [Ripple] {
        ripples.map { ripple in
            var copy = ripple
            copy.progress = CGFloat(min(max((time - ripple.born) / life, 0), 1))
            return copy
        }
    }
}
