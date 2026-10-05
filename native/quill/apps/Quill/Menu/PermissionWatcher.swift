import AppKit
import ApplicationServices

/// The Accessibility grant (ARCHITECTURE §3.5). A grant given while Quill runs makes
/// `AXIsProcessTrusted()` true, but synthetic events may still fail until a restart, so
/// the menu then offers "restart to finish enabling".
@MainActor
final class PermissionWatcher {
    enum State: Equatable {
        case trusted
        case notTrusted
        /// Trusted now, but it was not when Quill started.
        case grantedWhileRunning
    }

    private(set) var state: State
    private let isTrusted: () -> Bool
    private var timer: Timer?
    var onChange: ((State) -> Void)?

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.isTrusted = isTrusted
        state = isTrusted() ? .trusted : .notTrusted
    }

    static func next(_ state: State, trusted: Bool) -> State {
        switch (state, trusted) {
        case (.notTrusted, true): .grantedWhileRunning
        case (_, false): .notTrusted
        case (let state, true): state
        }
    }

    /// Re-reads the grant; the timer calls it, and so does every menu opening.
    func refresh() {
        let next = Self.next(state, trusted: isTrusted())
        guard next != state else { return }
        state = next
        onChange?(next)
        if timer != nil { start() }
    }

    /// How often to look: every second while the grant is missing — it can arrive at any
    /// moment while the user is in System Settings — and every 15 seconds once it is
    /// there, to notice a revocation. The menu and every capture look too, so the slow
    /// pace never leaves the user with a stale state.
    static func interval(for state: State) -> TimeInterval {
        state == .notTrusted ? 1 : 15
    }

    func start() {
        timer?.invalidate()
        let interval = Self.interval(for: state)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Lets macOS fold the wake-up into others instead of waking the CPU for it alone.
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// Starts a new instance and quits this one.
    static func restart() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }
}
