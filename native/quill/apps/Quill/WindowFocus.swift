import AppKit

/// Brings one of Quill's windows forward with the keyboard.
///
/// Quill is an accessory app, so whatever the user was in stays active, and since macOS 14
/// `activate()` is only a request the system may decline. It declined: Settings opened
/// behind the frontmost app, without the keyboard (reported 2026-11-06, reproduced with
/// Finder in front). Activating as if the frontmost app had handed over is what the
/// system honours for an action the user just took in Quill.
@MainActor
enum WindowFocus {
    static func bringForward(_ window: NSWindow?) {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            NSRunningApplication.current.activate(from: front, options: [])
        }
    }
}
