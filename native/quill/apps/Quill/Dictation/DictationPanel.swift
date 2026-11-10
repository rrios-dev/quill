import AppCore
import AppKit
import GlassUI
import SwiftUI

/// The dictation capsule (EFFICIENCY.md E8, J-18): one line, a fixed height and a true
/// capsule shape, beside the field the words will go to. A microphone that breathes with
/// the voice, the newest words — older ones leave by the start — and the shortcut that
/// finishes it (J-19: letting go of the keys never does). It never changes size while words arrive and never takes focus.
struct DictationPanelView: View {
    static let height: CGFloat = 46
    static let width: CGFloat = 420

    let model: DictationRewrite
    let shortcut: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            MicrophoneOrb(phase: model.phase, level: model.level, animated: !reduceMotion)
            words
                .frame(maxWidth: .infinity, alignment: .leading)
            if let tag {
                Text(tag)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
                    .fixedSize()
                    .transition(.opacity)
            }
            Button {
                Task {
                    if case .failed = model.phase { model.dismissFailure() } else { await model.cancel() }
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(.quaternary, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help(PickerCopy.string("dictation.cancel"))
            .accessibilityLabel(PickerCopy.string("dictation.cancel"))
        }
        .padding(.leading, 9)
        .padding(.trailing, 12)
        .frame(width: Self.width, height: Self.height)
        .accessibilityElement(children: .contain)
        .accessibilityHint(caption)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.phase)
    }

    @ViewBuilder private var words: some View {
        if case .failed(let message) = model.phase {
            Text(message)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(message)
        } else if model.text.isEmpty {
            Text(PickerCopy.string(model.phase == .listening ? "dictation.waiting" : "dictation.preparing"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        } else {
            let split = model.text.index(model.text.endIndex, offsetBy: -min(model.volatileCharacters, model.text.count))
            // The engine holds a whole sentence as provisional until it ends: the words
            // still being decided stay readable, a step lighter, never greyed out.
            (Text(model.text[..<split]) + Text(model.text[split...]).foregroundColor(.primary.opacity(0.72)))
                .font(.system(size: 14))
                // One line, the newest words in view: older ones leave by the start.
                .lineLimit(1)
                .truncationMode(.head)
                .accessibilityLabel(PickerCopy.string("dictation.heard \(model.text)"))
        }
    }

    /// The short tag at the end: the shortcut that finishes.
    private var tag: String? {
        switch model.phase {
        // The user's own shortcut, whatever they recorded: pressing it again finishes.
        case .listening: shortcut
        case .idle, .armed, .finishing, .failed: nil
        }
    }

    /// The same in full, for VoiceOver.
    private var caption: String {
        switch model.phase {
        case .idle, .armed: PickerCopy.string("dictation.preparing")
        case .listening: PickerCopy.string("dictation.hint \(shortcut)")
        case .finishing: PickerCopy.string("dictation.finishing")
        case .failed: PickerCopy.string("dictation.failed")
        }
    }
}

/// The microphone in a filled circle, with a halo that swells with the voice: one shape,
/// still when quiet, never a row of dots. A spinner while the model loads or the words
/// finish; a warning when it failed. Reduce Motion keeps the circle and drops the halo.
struct MicrophoneOrb: View {
    let phase: DictationRewrite.Phase
    let level: Float
    let animated: Bool

    var body: some View {
        ZStack {
            if case .listening = phase, animated {
                Circle()
                    .fill(Color.accentColor.opacity(0.22))
                    .frame(width: 28, height: 28)
                    .scaleEffect(1 + CGFloat(level) * 0.38)
                    .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.75), value: level)
            }
            Circle()
                .fill(fill)
                .frame(width: 28, height: 28)
            switch phase {
            case .listening:
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            case .failed:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            case .idle, .armed, .finishing:
                ProgressView().controlSize(.mini).tint(.white)
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }

    private var fill: Color {
        switch phase {
        case .failed: .orange
        case .listening: .accentColor
        case .idle, .armed, .finishing: .secondary.opacity(0.5)
        }
    }
}

/// The capsule's window: glass, just below the cursor the words go to — or, when the app
/// does not report one, low in the middle of the screen the pointer is on, where the
/// system's dictation shows when it cannot find the text either.
@MainActor
final class DictationPanelController {
    private var panel: PickerPanel?
    private var hosting: NSHostingView<DictationPanelView>?

    var window: NSWindow? { panel }

    func show(_ view: DictationPanelView, near anchor: DictationAnchor) {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let panel = PickerPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = Glass.makeWindowBackdrop(content: hosting, cornerRadius: DictationPanelView.height / 2)
        panel.setFrameOrigin(Self.origin(for: size, near: anchor))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        self.hosting = hosting
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        hosting = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { panel.dismiss() } })
    }

    /// Just below the cursor; for a field that does not report its cursor, just above the
    /// field, its leading edge aligned (a composer sits at the bottom of its window); with
    /// neither, low in the middle of the screen the pointer is on. Always on screen.
    static func origin(for size: CGSize, near anchor: DictationAnchor) -> NSPoint {
        let gap: CGFloat = 8
        func onScreen(_ point: NSPoint, _ rect: CGRect) -> NSPoint {
            let screen = (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return NSPoint(x: min(max(point.x, screen.minX + 8), screen.maxX - size.width - 8),
                           y: min(max(point.y, screen.minY + 8), screen.maxY - size.height - 8))
        }
        switch anchor {
        case .caret(let caret):
            var y = caret.minY - gap - size.height
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(caret) })?.visibleFrame, y < screen.minY {
                y = caret.maxY + gap
            }
            return onScreen(NSPoint(x: caret.minX - 18, y: y), caret)
        case .field(let field):
            return onScreen(NSPoint(x: field.minX, y: field.maxY + gap), field)
        case .none:
            let mouse = NSEvent.mouseLocation
            let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 96)
        }
    }
}

/// What the capsule is placed against.
enum DictationAnchor: Equatable {
    case caret(CGRect)
    case field(CGRect)
    case none
}
