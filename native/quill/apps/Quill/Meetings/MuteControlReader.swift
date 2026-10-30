import AppKit
import ApplicationServices
import ListenKit
import MeetingKit
import QuillSupport

/// Reads the meeting app's own microphone control through Accessibility and tells the
/// session's `MicrophoneGate` whether the user is muted there (J-10).
///
/// Teams, Zoom and Meet keep the microphone open while muted, so Core Audio cannot tell;
/// their mute button can, by its label ("Silenciar" while live, "Reactivar audio" while
/// muted — `MuteLabel`). The button is searched once in the app's windows (and menu bar,
/// where Zoom keeps "Mute audio"), then only its label is read, four times a second; a
/// button that disappears is searched for again. When nothing is found the gate hears
/// `nil`: unknown, and the live panel offers the user's own switch.
///
/// Every call runs on a private queue: an Accessibility call can block for the app's
/// messaging timeout, and Chromium apps answer slowly while they build their tree.
final class MuteControlReader: @unchecked Sendable {
    private let app: MeetingApp
    private let gate: MicrophoneGate
    private let queue = DispatchQueue(label: "dev.rrios.quill.meetings.mute", qos: .utility)
    private let log = QuillLog(category: "meetings")
    private var timer: DispatchSourceTimer?
    private var control: AXUIElement?
    private var lastSearch: Date = .distantPast
    private var lastLabel: String?

    /// How long a search may walk, and how often it may be repeated.
    static let searchBudget = 6_000
    static let searchInterval: TimeInterval = 3

    init(app: MeetingApp, gate: MicrophoneGate) {
        self.app = app
        self.gate = gate
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard AXIsProcessTrusted() else {
            gate.setAppControlMuted(nil)
            return
        }
        if let control, let state = Self.state(of: control) {
            gate.setAppControlMuted(state == .muted)
            return
        }
        control = nil
        guard Date().timeIntervalSince(lastSearch) >= Self.searchInterval else { return }
        lastSearch = Date()
        control = search()
        if let control, let state = Self.state(of: control) {
            gate.setAppControlMuted(state == .muted)
        } else {
            gate.setAppControlMuted(nil)
        }
    }

    /// The app's processes with windows: the main app, not its audio helpers.
    private var applications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { running in
            running.activationPolicy == .regular && (running.bundleIdentifier.map(app.matches) ?? false)
        }
    }

    private func search() -> AXUIElement? {
        for running in applications {
            let element = AXUIElementCreateApplication(running.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)
            // Chromium builds its web tree only for assistive apps that ask
            // (`SelectionOperations`); Teams and the browsers are Chromium.
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            // Windows first: a call's button is deep in the web tree, and the menu bar's
            // shallow items would win a single search (Zoom's "Mute audio" lives there).
            let menuBar = Self.element(kAXMenuBarAttribute, of: element).map { [$0] } ?? []
            if let found = Self.breadthFirst(from: Self.elements("AXWindows", of: element), budget: Self.searchBudget)
                ?? Self.breadthFirst(from: menuBar, budget: Self.searchBudget) {
                let label = Self.label(of: found) ?? ""
                if label != lastLabel {
                    log.info("mute control found in \(running.bundleIdentifier ?? "?"): \(label)")
                    lastLabel = label
                }
                return found
            }
        }
        return nil
    }

    /// The first control whose label is a microphone's, nearest the top first.
    static func breadthFirst(from roots: [AXUIElement], budget: Int) -> AXUIElement? {
        var queue = roots[...]
        var visited = 0
        while let element = queue.popFirst(), visited < budget {
            visited += 1
            if isControl(element), state(of: element) != nil { return element }
            queue.append(contentsOf: elements(kAXChildrenAttribute, of: element))
        }
        return nil
    }

    static func isControl(_ element: AXUIElement) -> Bool {
        let role = string(kAXRoleAttribute, of: element) ?? ""
        return [kAXButtonRole, kAXCheckBoxRole, kAXMenuItemRole, "AXToggle", kAXRadioButtonRole].contains(role)
    }

    static func state(of element: AXUIElement) -> MuteLabel.State? {
        label(of: element).flatMap(MuteLabel.state(of:))
    }

    /// What the control says it does: its description, title or help, whichever names a
    /// microphone action.
    static func label(of element: AXUIElement) -> String? {
        [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute]
            .compactMap { string($0, of: element) }
            .first { MuteLabel.state(of: $0) != nil }
    }

    static func string(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func element(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func elements(_ attribute: String, of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }
}
