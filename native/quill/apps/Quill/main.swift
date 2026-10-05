import AppKit

// No storyboard and no `@main`: Quill is a menu bar agent, so the application is
// built by hand and its activation policy set before the run loop starts.

// Before anything touches the data folder, the Keychain or the hot key.
if CommandLine.arguments.contains(SelfCheck.argument) {
    exit(SelfCheck.run())
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate

// `.accessory`: no Dock icon and no menu bar of its own. Quill lives in the status
// bar and behind its global shortcut.
application.setActivationPolicy(.accessory)

application.run()
