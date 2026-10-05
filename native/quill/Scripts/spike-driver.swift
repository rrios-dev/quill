#!/usr/bin/env swift
//
// Drives the spike matrix (PLAN P0-T4, SPIKES.md) from a terminal.
//
// It puts a known text in a known field of a native app, selects part of it, and asks
// the running **debug** build of Quill to probe it or to open the picker harness over
// it, through the distributed notifications its Debug menu listens to. Quill does the
// measuring with its own Accessibility grant; this script only arranges the scene and
// reads the rows Quill writes to `<data dir>/probe/`.
//
// The script itself uses the Accessibility API to arrange the scene, so the terminal
// running it needs the Accessibility permission. It never types into an app beyond the
// fixture text, never sends anything, and cleans up the notes and drafts it creates.
//
//   swift Scripts/spike-driver.swift prepare <textedit|textedit-rich|notes|mail|fields>
//   swift Scripts/spike-driver.swift focus <AXRole> [index]
//   swift Scripts/spike-driver.swift probe <tag> [none|paste|accessibilityWrite] [restoreDelayMs] [enhanced] [copy] [sequences]
//   swift Scripts/spike-driver.swift harness <tag>
//   swift Scripts/spike-driver.swift live-provider <tag>
//   swift Scripts/spike-driver.swift undo
//   swift Scripts/spike-driver.swift state
//   swift Scripts/spike-driver.swift menu
//   swift Scripts/spike-driver.swift settings [general|providers|profiles|apps|about]
//   swift Scripts/spike-driver.swift onboarding [next|back]…
//   swift Scripts/spike-driver.swift first-token
//   swift Scripts/spike-driver.swift picker [keys…]   (after `prepare`; keys: esc return cmd-return d r 1–9)
//   swift Scripts/spike-driver.swift fullscreen <on|off>
//   swift Scripts/spike-driver.swift cleanup <notes|mail>
//
import AppKit
import ApplicationServices
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

let fixture = "hello john, I will send you the report tomorrow\n"
/// "hello john" by default; `SPIKE_RANGE=<location>,<length>` selects elsewhere (the rich
/// test field's bold words, for one).
let selection: CFRange = {
    let parts = (ProcessInfo.processInfo.environment["SPIKE_RANGE"] ?? "").split(separator: ",").compactMap { Int($0) }
    return parts.count == 2 ? CFRange(location: parts[0], length: parts[1]) : CFRange(location: 0, length: 10)
}()
/// The data folder's `probe/`: `QUILL_DATA_DIR` when the build under test was launched
/// with one (the walkthrough build), else the development build's.
let probeFolder = (ProcessInfo.processInfo.environment["QUILL_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/dev.rrios.quill", isDirectory: true))
    .appendingPathComponent("probe", isDirectory: true)
let stateFile = FileManager.default.temporaryDirectory.appendingPathComponent("quill-spike-target")
/// Present while the prepared document is rich text: its value is not reset to the
/// plain fixture before each run, which would drop the formatting under test.
let keepValueFile = FileManager.default.temporaryDirectory.appendingPathComponent("quill-spike-keep-value")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    exit(1)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, "AXChildren") as? [AXUIElement]) ?? []
}

func descendants(_ element: AXUIElement, depth: Int = 0, where match: (AXUIElement) -> Bool) -> AXUIElement? {
    guard depth < 40 else { return nil }
    for child in children(element) {
        if match(child) { return child }
        if let found = descendants(child, depth: depth + 1, where: match) { return found }
    }
    return nil
}

func role(_ element: AXUIElement) -> String { attribute(element, "AXRole") as? String ?? "" }

func runningApp(_ bundleIdentifier: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
}

func osascript(_ source: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func bringToFront(_ bundleIdentifier: String) {
    for _ in 0..<5 {
        _ = osascript("tell application id \"\(bundleIdentifier)\" to activate")
        Thread.sleep(forTimeInterval: 0.5)
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier { return }
    }
    fail("could not bring \(bundleIdentifier) to the front (frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))")
}

func focusedElement(of bundleIdentifier: String) -> AXUIElement? {
    guard let app = runningApp(bundleIdentifier) else { return nil }
    return attribute(AXUIElementCreateApplication(app.processIdentifier), "AXFocusedUIElement")
        .map { unsafeDowncast($0, to: AXUIElement.self) }
}

func select(_ range: CFRange, in element: AXUIElement) {
    var range = range
    AXUIElementSetAttributeValue(element, "AXSelectedTextRange" as CFString, AXValueCreate(.cfRange, &range)!)
}

func selectedRange(_ element: AXUIElement) -> CFRange? {
    guard let value = attribute(element, "AXSelectedTextRange") else { return nil }
    var range = CFRange()
    return AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) ? range : nil
}

func target() -> String {
    guard let bundleIdentifier = try? String(contentsOf: stateFile, encoding: .utf8) else { fail("run `prepare` first") }
    return bundleIdentifier
}

func argument(_ index: Int, _ usage: String) -> String {
    guard arguments.count > index else { fail(usage) }
    return arguments[index]
}

/// Brings the prepared app forward, resets its field to the fixture and selects "hello john".
func arrange() -> AXUIElement {
    let bundleIdentifier = target()
    bringToFront(bundleIdentifier)
    guard let field = focusedElement(of: bundleIdentifier) else { fail("\(bundleIdentifier) has no focused element") }
    if bundleIdentifier == "com.apple.TextEdit", !FileManager.default.fileExists(atPath: keepValueFile.path) {
        AXUIElementSetAttributeValue(field, "AXValue" as CFString, fixture as CFString)
    }
    if selectedRange(field) == nil {
        // WebKit bodies (Mail) have no settable range: select everything with ⌘A,
        // which inside the draft's body selects only the body.
        postCommand(0)   // kVK_ANSI_A
    } else {
        select(selection, in: field)
    }
    Thread.sleep(forTimeInterval: 0.2)
    return field
}

func post(_ name: String, _ info: [String: String]) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(name), object: nil, userInfo: info, deliverImmediately: true)
}

func waitForRow(tag: String, timeout: TimeInterval = 15) -> String {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let files = (try? FileManager.default.contentsOfDirectory(at: probeFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            if let text = try? String(contentsOf: file, encoding: .utf8), text.contains("\"tag\" : \"\(tag)\"") {
                return text
            }
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    fail("no row tagged \(tag) within \(Int(timeout)) s — is the debug build of Quill running?")
}

func value(_ element: AXUIElement) -> String { attribute(element, "AXValue") as? String ?? "" }

func postCommand(_ keyCode: CGKeyCode) {
    let source = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
        event?.flags = .maskCommand
        event?.post(tap: .cghidEventTap)
    }
}

/// A key with modifiers, posted at the HID level like a real keystroke.
func postKey(_ keyCode: CGKeyCode, _ flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
    // A person lets go of the modifiers too. Without this flags-changed event the HID
    // state keeps them "held", and Quill's ⌘C path rightly refuses (modifiersHeld).
    if !flags.isEmpty, let release = CGEvent(source: source) {
        release.type = .flagsChanged
        release.flags = []
        release.post(tap: .cghidEventTap)
    }
}

/// The session as the debug build reports it (`probe/session.txt`).
func sessionDump() -> String {
    let dump = probeFolder.appendingPathComponent("session.txt")
    try? FileManager.default.removeItem(at: dump)
    post("dev.rrios.quill.debug.session.dump", [:])
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, !FileManager.default.fileExists(atPath: dump.path) { Thread.sleep(forTimeInterval: 0.05) }
    return (try? String(contentsOf: dump, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "no session dump"
}

func windowsOnScreen(_ bundleIdentifier: String) -> Int {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == runningApp(bundleIdentifier)?.processIdentifier }
        .filter { ($0[kCGWindowLayer as String] as? Int) != 25 }   // not the menu bar's status items
        .count
}

func quillWindowsOnScreen() -> Int { windowsOnScreen("dev.rrios.quill") }

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("usage: see the header of this script") }

switch command {
case "prepare":
    let app = arguments.count > 1 ? arguments[1] : ""
    try? FileManager.default.removeItem(at: keepValueFile)
    switch app {
    case "textedit-rich":
        // "hello john" in bold, the rest plain.
        let text = NSMutableAttributedString(string: fixture, attributes: [.font: NSFont(name: "Helvetica", size: 14)!])
        text.addAttribute(.font, value: NSFont(name: "Helvetica-Bold", size: 14)!, range: NSRange(location: 0, length: 10))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("quill-spike.rtf")
        let data = try? text.data(from: NSRange(location: 0, length: text.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        // Written only when TextEdit does not hold it open (see "textedit" below).
        if !FileManager.default.fileExists(atPath: file.path) { try? data?.write(to: file) }
        NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        Thread.sleep(forTimeInterval: 1.5)
        try? Data().write(to: keepValueFile)
        try? "com.apple.TextEdit".write(to: stateFile, atomically: true, encoding: .utf8)
    case "textedit":
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("quill-spike.txt")
        // Written once: rewriting the file under the open document makes TextEdit raise
        // its "another application has modified the file" sheet at the next autosave,
        // which then swallows every key and Apple Event. `arrange` resets the text
        // through accessibility before each run instead.
        if !FileManager.default.fileExists(atPath: file.path) {
            try? fixture.write(to: file, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        Thread.sleep(forTimeInterval: 1.5)
        try? "com.apple.TextEdit".write(to: stateFile, atomically: true, encoding: .utf8)
    case "notes":
        _ = osascript("""
        tell application "Notes"
            activate
            set spikeNote to make new note with properties {name:"Quill spike (temporary)", body:"\(fixture.trimmingCharacters(in: .newlines))"}
            show spikeNote
        end tell
        """)
        Thread.sleep(forTimeInterval: 1.5)
        try? "com.apple.Notes".write(to: stateFile, atomically: true, encoding: .utf8)
    case "mail":
        _ = osascript("""
        tell application "Mail"
            activate
            make new outgoing message with properties {subject:"Quill spike (temporary, never sent)", content:"\(fixture.trimmingCharacters(in: .newlines))", visible:true}
        end tell
        """)
        Thread.sleep(forTimeInterval: 2)
        try? "com.apple.mail".write(to: stateFile, atomically: true, encoding: .utf8)
    case "fields":
        post("dev.rrios.quill.debug.fields.open", [:])
        Thread.sleep(forTimeInterval: 1)
        try? "dev.rrios.quill".write(to: stateFile, atomically: true, encoding: .utf8)
    default:
        fail("prepare textedit|notes|mail|fields")
    }
    print("prepared \(target())")

case "focus":
    // focus <role> [index]: moves keyboard focus to the n-th element of a role in the
    // front window of the prepared app (Notes' body, Mail's message body, a test field).
    let wanted = arguments.count > 1 ? arguments[1] : "AXTextArea"
    let index = arguments.count > 2 ? Int(arguments[2]) ?? 0 : 0
    let bundleIdentifier = target()
    bringToFront(bundleIdentifier)
    guard let app = runningApp(bundleIdentifier),
          let window = attribute(AXUIElementCreateApplication(app.processIdentifier), "AXFocusedWindow")
    else { fail("no focused window") }
    var matches: [AXUIElement] = []
    func collect(_ element: AXUIElement, _ depth: Int) {
        guard depth < 40 else { return }
        for child in children(element) {
            if role(child) == wanted { matches.append(child) }
            collect(child, depth + 1)
        }
    }
    collect(unsafeDowncast(window, to: AXUIElement.self), 0)
    guard matches.indices.contains(index) else { fail("no \(wanted) #\(index) (found \(matches.count))") }
    AXUIElementSetAttributeValue(matches[index], "AXFocused" as CFString, kCFBooleanTrue)
    Thread.sleep(forTimeInterval: 0.3)
    print("focused \(wanted) #\(index); focused element role:", focusedElement(of: bundleIdentifier).map(role) ?? "-")

case "probe":
    let tag = argument(1, "probe <tag>")
    let replace = arguments.count > 2 ? arguments[2] : "none"
    let delay = arguments.count > 3 ? arguments[3] : "300"
    let flags = Set(arguments.dropFirst(4))
    let enhanced = flags.contains("enhanced") ? "1" : "0"
    let forceCopy = flags.contains("copy") ? "1" : "0"
    let sequences = flags.contains("sequences") ? "1" : "0"
    let field = arrange()
    let before = value(field)
    post("dev.rrios.quill.debug.probe", ["tag": tag, "replace": replace, "restoreDelay": delay, "enhanced": enhanced, "forceCopy": forceCopy, "sequences": sequences])
    let row = waitForRow(tag: tag)
    print(row)
    print("frontmost after:", NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")
    print("value changed:", value(field) != before)

case "menu":
    // The status menu as Quill builds it on opening (P3-T2), written by its debug hook.
    let dump = probeFolder.appendingPathComponent("menu.txt")
    try? FileManager.default.removeItem(at: dump)
    post("dev.rrios.quill.debug.menu.dump", [:])
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline, !FileManager.default.fileExists(atPath: dump.path) { Thread.sleep(forTimeInterval: 0.1) }
    guard let text = try? String(contentsOf: dump, encoding: .utf8) else { fail("no menu dump within 10 s — is the debug build running?") }
    print(text, terminator: "")

case "first-token":
    let file = probeFolder.appendingPathComponent("perf.txt")
    try? FileManager.default.removeItem(at: file)
    post("dev.rrios.quill.debug.perf.firstToken", [:])
    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline, !FileManager.default.fileExists(atPath: file.path) { Thread.sleep(forTimeInterval: 0.5) }
    print((try? String(contentsOf: file, encoding: .utf8)) ?? "no result within 180 s", terminator: "")

case "onboarding":
    // The first run's state, after each action (P5-T1's walkthrough).
    let dump = probeFolder.appendingPathComponent("onboarding.txt")
    for action in [""] + arguments.dropFirst() {
        try? FileManager.default.removeItem(at: dump)
        post("dev.rrios.quill.debug.onboarding", action.isEmpty ? [:] : ["action": action])
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !FileManager.default.fileExists(atPath: dump.path) { Thread.sleep(forTimeInterval: 0.05) }
        let text = (try? String(contentsOf: dump, encoding: .utf8)) ?? "no dump\n"
        print(action.isEmpty ? "now:" : "after \(action):", text.replacingOccurrences(of: "\n", with: " · "))
        Thread.sleep(forTimeInterval: 0.6)
    }

case "settings":
    post("dev.rrios.quill.debug.settings.open", arguments.count > 1 ? ["pane": arguments[1]] : [:])
    Thread.sleep(forTimeInterval: 1.5)
    print("quill windows on screen:", quillWindowsOnScreen())

case "picker":
    // The real flow (P3-T4): the global shortcut over the prepared field, then keys.
    let field = arrange()
    let before = selectedRange(field).map { "\($0.location)+\($0.length)" } ?? "-"
    postKey(15, [.maskControl, .maskAlternate])   // ⌃⌥R, the default shortcut
    Thread.sleep(forTimeInterval: 2.0)
    print("selection before:", before)
    print("frontmost while open:", NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")
    print("selection while open:", selectedRange(field).map { "\($0.location)+\($0.length)" } ?? "-")
    print("quill windows on screen while open:", quillWindowsOnScreen())
    print("host windows on screen while open:", windowsOnScreen(target()))
    print("session:", sessionDump().replacingOccurrences(of: "\n", with: " · "))
    let keys: [String: (CGKeyCode, CGEventFlags)] = [
        "esc": (53, []), "return": (36, []), "cmd-return": (36, .maskCommand), "d": (2, .maskCommand), "r": (15, .maskCommand),
        "1": (18, []), "2": (19, []), "3": (20, []), "4": (21, []),
    ]
    for name in arguments.dropFirst() {
        guard let (code, flags) = keys[name] else { fail("unknown key \(name)") }
        postKey(code, flags)
        Thread.sleep(forTimeInterval: 1.5)
        print("after \(name):", sessionDump().replacingOccurrences(of: "\n", with: " · "))
    }
    print("frontmost after:", NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")
    print("selection after:", selectedRange(field).map { "\($0.location)+\($0.length)" } ?? "-")
    print("quill windows on screen after:", quillWindowsOnScreen())
    print("host windows on screen after:", windowsOnScreen(target()))
    if let focused = focusedElement(of: target()) { print("value after:", value(focused).prefix(80)) }

case "harness":
    let tag = argument(1, "harness <tag>")
    let field = arrange()
    post("dev.rrios.quill.debug.harness.open", ["tag": tag])
    Thread.sleep(forTimeInterval: 1.2)
    print("frontmost while open:", NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")
    print("selection while open:", selectedRange(field).map { "\($0.location)+\($0.length)" } ?? "-")
    let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == runningApp("dev.rrios.quill")?.processIdentifier }
    print("quill windows on screen while open:", onScreen.count)
    post("dev.rrios.quill.debug.harness.close", [:])
    print(waitForRow(tag: tag))
    print("frontmost after close:", NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")

case "live-provider":
    // Asks Quill to run its 30-call on-device burst and prints the row.
    let tag = argument(1, "live-provider <tag>")
    post("dev.rrios.quill.debug.liveprovider", ["tag": tag])
    print(waitForRow(tag: tag, timeout: 300))

case "undo":
    bringToFront(target())
    postCommand(6)   // kVK_ANSI_Z: undo is checked in the layout-independent ANSI position
    Thread.sleep(forTimeInterval: 0.4)
    if let field = focusedElement(of: target()) { print("value after ⌘Z:", value(field).prefix(80)) }

case "state":
    if let field = focusedElement(of: target()) {
        print("role:", role(field), "value:", value(field).prefix(80), "selection:", selectedRange(field).map { "\($0.location)+\($0.length)" } ?? "-")
    }

case "fullscreen":
    let on = arguments.count > 1 && arguments[1] == "on"
    let bundleIdentifier = target()
    bringToFront(bundleIdentifier)
    guard let app = runningApp(bundleIdentifier),
          let window = attribute(AXUIElementCreateApplication(app.processIdentifier), "AXFocusedWindow")
    else { fail("no focused window") }
    AXUIElementSetAttributeValue(unsafeDowncast(window, to: AXUIElement.self), "AXFullScreen" as CFString,
                                 (on ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    Thread.sleep(forTimeInterval: 1.5)
    print("full screen:", attribute(unsafeDowncast(window, to: AXUIElement.self), "AXFullScreen") as? Bool ?? false)

case "cleanup":
    let app = arguments.count > 1 ? arguments[1] : ""
    switch app {
    case "notes":
        Thread.sleep(forTimeInterval: 1.5)   // Notes finishes saving the edit first
        // By id: `delete (every note whose …)` returns without deleting anything.
        print(osascript("""
        tell application "Notes"
            repeat with spikeNote in (every note whose name is "Quill spike (temporary)")
                set noteId to id of spikeNote
                delete note id noteId
            end repeat
            return "notes left: " & (count (every note whose name is "Quill spike (temporary)"))
        end tell
        """))
    case "mail":
        print(osascript("""
        tell application "Mail"
            repeat with m in (every outgoing message whose subject is "Quill spike (temporary, never sent)")
                close m saving no
            end repeat
            -- Mail autosaves drafts; deleting moves the copy to the Trash. A snapshot of
            -- the list, deleted from the end: a live `whose` reference loses its items as
            -- they go and fails with -1728.
            delay 1
            set found to (every message of drafts mailbox whose subject is "Quill spike (temporary, never sent)")
            repeat with i from (count found) to 1 by -1
                delete (item i of found)
            end repeat
            delay 1
            return "drafts left: " & (count (every message of drafts mailbox whose subject is "Quill spike (temporary, never sent)"))
        end tell
        """))
    default:
        fail("cleanup notes|mail")
    }

default:
    fail("unknown command \(command)")
}
