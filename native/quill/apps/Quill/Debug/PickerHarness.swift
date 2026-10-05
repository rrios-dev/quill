#if DEBUG

import AppKit
import QuillSupport
import SelectionKit
import SwiftUI

/// Debug → Picker harness (ARCHITECTURE §3.6): opens a stand-in picker over the
/// frontmost app with a fixed text, built with the picker's exact panel configuration,
/// for spike S3: does it take the keyboard without stealing the host's selection, and
/// how does focus come back when it closes — the same element, or only the same app?
///
/// Each open-and-close writes one row to `<data dir>/probe/`.
@MainActor
final class PickerHarness {
    /// What was focused when the harness opened.
    struct Captured: Sendable {
        var element: AccessibilityElement
        var pid: pid_t?
        var range: CFRange?
        var bundleIdentifier: String?
        var anchor: CGRect?
    }

    struct Row: Codable, Sendable {
        var kind = "harness"
        var date: Date
        var tag: String?
        var bundleIdentifier: String?
        var anchorSource: String
        var frontmostWhileOpen: String?
        var panelWasKey: Bool
        var selectionKeptWhileOpen: Bool?
        /// Time for `AXFocusedApplication` to be the captured app again.
        var pidReturnMilliseconds: Double?
        /// Time for the focused element to equal (`CFEqual`) the captured one.
        var elementReturnMilliseconds: Double?
        var selectionKeptAfterClose: Bool?
    }

    private var panel: PickerPanel?
    private var captured: Captured?
    private var tag: String?
    private var rowWhileOpen: (frontmost: String?, key: Bool, kept: Bool?)?
    private let operations: SelectionOperations
    private let log = QuillLog(category: "harness")
    var onRowWritten: ((URL) -> Void)?

    init(operations: SelectionOperations) {
        self.operations = operations
    }

    func open(captured: Captured?, tag: String?) {
        close()
        self.captured = captured
        self.tag = tag
        let size = NSSize(width: 360, height: 120)
        let panel = PickerPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.onCancel = { [weak self] in self?.close() }

        let hosting = NSHostingView(rootView: HarnessView(onClose: { [weak self] in self?.close() }))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        let anchor = captured?.anchor ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        panel.setFrameOrigin(Self.origin(for: size, near: anchor))
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        // Measured a moment after opening, once the window server has settled.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, let panel = self.panel else { return }
            let operations = self.operations
            let element = captured?.element
            let range = captured?.range
            let kept = await Task.detached { () -> Bool? in
                guard let element, let range else { return nil }
                let now = operations.readSelection(of: element).range
                return now.map { $0.location == range.location && $0.length == range.length }
            }.value
            self.rowWhileOpen = (NSWorkspace.shared.frontmostApplication?.bundleIdentifier, panel.isKeyWindow, kept)
        }
    }

    /// Closes the panel, then measures how focus returns (ARCHITECTURE §3.2 step 3:
    /// one 600 ms cap, polled at 4 ms).
    func close() {
        guard let panel else { return }
        panel.dismiss()
        self.panel = nil
        let captured = captured
        let tag = tag
        let whileOpen = rowWhileOpen
        rowWhileOpen = nil
        let operations = operations
        Task { @MainActor [weak self] in
            let measured = await Task.detached { () -> (Double?, Double?, Bool?) in
                await Self.measureReturn(captured: captured, operations: operations)
            }.value
            let row = Row(
                date: Date(),
                tag: tag,
                bundleIdentifier: captured?.bundleIdentifier,
                anchorSource: captured?.anchor == nil ? "mouse" : "accessibility",
                frontmostWhileOpen: whileOpen?.frontmost,
                panelWasKey: whileOpen?.key ?? false,
                selectionKeptWhileOpen: whileOpen?.kept,
                pidReturnMilliseconds: measured.0,
                elementReturnMilliseconds: measured.1,
                selectionKeptAfterClose: measured.2
            )
            do {
                let url = try ProbeRunner.save(row, named: "harness-\(captured?.bundleIdentifier ?? "unknown")", date: row.date, in: AppPaths.current)
                self?.onRowWritten?(url)
            } catch {
                self?.log.error("harness row not written: \(error)")
            }
        }
    }

    nonisolated static func measureReturn(
        captured: Captured?, operations: SelectionOperations
    ) async -> (Double?, Double?, Bool?) {
        guard let captured else { return (nil, nil, nil) }
        let clock = ContinuousClock()
        let start = clock.now
        var pidAt: Double?
        var elementAt: Double?
        _ = await Polling.wait(timeout: .milliseconds(600), clock: clock) {
            let elapsed = ProbeRunner.milliseconds(clock.now - start)
            if pidAt == nil, let pid = captured.pid, operations.focusedApplicationPID() == pid { pidAt = elapsed }
            if elementAt == nil, case .success(let focused) = operations.focusedElement(),
               focused.element == captured.element {
                elementAt = elapsed
            }
            return pidAt != nil && elementAt != nil
        }
        var kept: Bool?
        if let range = captured.range, let now = operations.readSelection(of: captured.element).range {
            kept = now.location == range.location && now.length == range.length
        }
        return (pidAt, elementAt, kept)
    }

    /// The picker's placement rule (SelectionKit's PickerPlacement), on the real screens.
    static func origin(for size: NSSize, near anchor: CGRect) -> NSPoint {
        PickerPlacement.origin(panelSize: size, anchor: anchor, mouse: NSEvent.mouseLocation,
                               screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) })
    }
}

private struct HarnessView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("debug.harness.title", bundle: .localized)
                .font(.headline)
            Text("debug.harness.body", bundle: .localized)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(String(localized: "debug.harness.close", bundle: .localized), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#endif
