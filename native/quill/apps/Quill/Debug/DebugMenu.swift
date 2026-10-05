#if DEBUG

import AppKit
import ApplicationServices
import QuillSupport
import SelectionKit

/// The Debug submenu of development builds (ARCHITECTURE §3.6). Compiled out of release
/// builds, with everything it opens.
@MainActor
final class DebugMenu: NSObject {
    private weak var statusItem: NSStatusItem?
    private var options = ProbeRunner.Options()
    private var lastProbe: URL?
    private var probing = false
    private let harness = PickerHarness(operations: DebugMenu.liveOperations())
    private let testFields = TestFieldsWindow()
    private let log = QuillLog(category: "debug")

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        super.init()
        harness.onRowWritten = { [weak self] url in self?.lastProbe = url }
        listenToSpikeDriver()
    }

    func makeItem() -> NSMenuItem {
        let submenu = NSMenu()

        let trusted = AXIsProcessTrusted()
        submenu.addItem(disabled(trusted
            ? String(localized: "debug.accessibility.trusted", bundle: .localized)
            : String(localized: "debug.accessibility.notTrusted", bundle: .localized)))
        if !trusted {
            let request = item(String(localized: "debug.accessibility.request", bundle: .localized), #selector(requestAccessibility))
            request.isEnabled = !DebugHooks.suppressesPrompts
            submenu.addItem(request)
        }
        submenu.addItem(.separator())

        let probe = item(String(localized: "debug.probe.run", bundle: .localized), #selector(runProbe))
        probe.isEnabled = !probing
        submenu.addItem(probe)
        submenu.addItem(optionsItem())
        if lastProbe != nil {
            submenu.addItem(item(String(localized: "debug.probe.reveal", bundle: .localized), #selector(revealLastProbe)))
        }
        submenu.addItem(.separator())
        let harnessItem = item(String(localized: "debug.harness.open", bundle: .localized), #selector(openHarness))
        harnessItem.isEnabled = !probing
        submenu.addItem(harnessItem)
        submenu.addItem(item(String(localized: "debug.fields.open", bundle: .localized), #selector(openTestFields)))
        submenu.addItem(.separator())
        let live = item(String(localized: "debug.liveProvider.run", bundle: .localized), #selector(runLiveProviderTest))
        live.isEnabled = !probing
        submenu.addItem(live)

        let root = NSMenuItem(title: String(localized: "debug.menu", bundle: .localized), action: nil, keyEquivalent: "")
        root.submenu = submenu
        return root
    }

    private func optionsItem() -> NSMenuItem {
        let menu = NSMenu()

        let enhanced = item(String(localized: "debug.probe.enhanced", bundle: .localized), #selector(toggleEnhanced))
        enhanced.state = options.enhancedAccessibility ? .on : .off
        menu.addItem(enhanced)
        menu.addItem(.separator())

        let replaceTitles: [(ProbeRunner.ReplaceMode, String)] = [
            (.none, String(localized: "debug.probe.replace.none", bundle: .localized)),
            (.paste, String(localized: "debug.probe.replace.paste", bundle: .localized)),
            (.accessibilityWrite, String(localized: "debug.probe.replace.accessibility", bundle: .localized)),
        ]
        for (mode, title) in replaceTitles {
            let entry = item(title, #selector(chooseReplace(_:)))
            entry.representedObject = mode.rawValue
            entry.state = options.replace == mode ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        for delay in ProbeRunner.Options.restoreDelays {
            let entry = item(String(localized: "debug.probe.restoreDelay \(delay)", bundle: .localized), #selector(chooseDelay(_:)))
            entry.tag = delay
            entry.state = options.restoreDelayMilliseconds == delay ? .on : .off
            menu.addItem(entry)
        }

        let root = NSMenuItem(title: String(localized: "debug.probe.options", bundle: .localized), action: nil, keyEquivalent: "")
        root.submenu = menu
        return root
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Actions

    /// Asks macOS to show its Accessibility prompt, which also lists Quill in System
    /// Settings so the grant can be given there.
    @objc private func requestAccessibility() {
        guard !DebugHooks.suppressesPrompts else { return }
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @objc private func toggleEnhanced() { options.enhancedAccessibility.toggle() }

    @objc private func chooseReplace(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = ProbeRunner.ReplaceMode(rawValue: raw) {
            options.replace = mode
        }
    }

    @objc private func chooseDelay(_ sender: NSMenuItem) { options.restoreDelayMilliseconds = sender.tag }

    @objc private func revealLastProbe() {
        if let lastProbe { NSWorkspace.shared.activateFileViewerSelecting([lastProbe]) }
    }

    @objc private func openHarness() { startHarness(tag: nil, countdownSeconds: 3) }

    /// Counts down, then opens the stand-in picker over whatever app is frontmost, at its
    /// selection's bounds when accessibility reports them.
    private func startHarness(tag: String?, countdownSeconds: Int) {
        guard !probing else { return }
        probing = true
        Task { @MainActor in
            await countdown(countdownSeconds)
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let operations = Self.liveOperations()
            let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let captured = await Task.detached { () -> PickerHarness.Captured? in
                operations.configureMessagingTimeout()
                guard case .success(let focused) = operations.focusedElement() else { return nil }
                let read = operations.readSelection(of: focused.element)
                let anchor: CGRect? = read.isSecureField ? nil : read.range.flatMap {
                    operations.selectionBounds(of: focused.element, range: $0, primaryScreenHeight: primaryHeight)
                }
                return PickerHarness.Captured(
                    element: focused.element, pid: focused.pid, range: read.range,
                    bundleIdentifier: bundleIdentifier, anchor: anchor)
            }.value
            harness.open(captured: captured, tag: tag)
            probing = false
        }
    }

    private func countdown(_ seconds: Int = 3) async {
        for second in stride(from: seconds, to: 0, by: -1) {
            statusItem?.button?.title = " \(second)"
            try? await Task.sleep(for: .seconds(1))
        }
        statusItem?.button?.title = ""
    }

    private static func liveOperations() -> SelectionOperations {
        SelectionOperations(
            accessibility: LiveAccessibilityClient(),
            pasteboard: LivePasteboardClient(),
            keys: LiveKeyEventPoster()
        )
    }

    @objc private func openTestFields() { testFields.show() }

    /// Counts down three seconds in the status item — time to bring the target app
    /// forward and select text — then probes whatever app is frontmost.
    @objc private func runProbe() { startProbe(options: options, tag: nil, countdownSeconds: 3) }

    private func startProbe(options: ProbeRunner.Options, tag: String?, countdownSeconds: Int) {
        guard !probing else { return }
        probing = true
        Task { @MainActor in
            await countdown(countdownSeconds)

            let frontmost = NSWorkspace.shared.frontmostApplication
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let runner = ProbeRunner(operations: Self.liveOperations(), primaryScreenHeight: primaryHeight)
            let row = await Task.detached { await runner.run(options: options, frontmost: frontmost, tag: tag) }.value
            do {
                lastProbe = try ProbeRunner.save(row, in: AppPaths.current)
                log.info("probe row written to \(lastProbe?.path ?? "?")")
            } catch {
                log.error("probe row not written: \(error)")
            }
            probing = false
        }
    }

    @objc private func runLiveProviderTest() { startLiveProviderTest(tag: nil) }

    private func startLiveProviderTest(tag: String?) {
        guard !probing else { return }
        probing = true
        statusItem?.button?.title = " …"
        Task { @MainActor in
            let row = await Task.detached { await LiveProviderTest().run(tag: tag) }.value
            do {
                lastProbe = try ProbeRunner.save(row, named: "live-provider", date: row.date, in: AppPaths.current)
            } catch {
                log.error("live provider row not written: \(error)")
            }
            statusItem?.button?.title = ""
            probing = false
        }
    }

    // MARK: Spike driver

    /// Distributed notifications the spike driver (`Scripts/spike-driver.swift`) posts,
    /// so a matrix run can trigger the probe and the harness without opening this menu —
    /// opening a status-bar menu from a script hands activation to another app when it
    /// closes. Debug builds only, like every other hook.
    enum DriverNotification {
        static let probe = Notification.Name("dev.rrios.quill.debug.probe")
        static let harnessOpen = Notification.Name("dev.rrios.quill.debug.harness.open")
        static let harnessClose = Notification.Name("dev.rrios.quill.debug.harness.close")
        static let testFields = Notification.Name("dev.rrios.quill.debug.fields.open")
        static let liveProvider = Notification.Name("dev.rrios.quill.debug.liveprovider")
    }

    func listenToSpikeDriver() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: DriverNotification.probe, object: nil, queue: .main) { [weak self] note in
            let info = Self.strings(note.userInfo)
            MainActor.assumeIsolated {
                var options = ProbeRunner.Options()
                options.enhancedAccessibility = info["enhanced"] == "1"
                options.replace = info["replace"].flatMap(ProbeRunner.ReplaceMode.init(rawValue:)) ?? .none
                options.restoreDelayMilliseconds = info["restoreDelay"].flatMap(Int.init) ?? 300
                options.forceCopy = info["forceCopy"] == "1"
                options.sequences = info["sequences"] == "1"
                self?.startProbe(options: options, tag: info["tag"], countdownSeconds: info["countdown"].flatMap(Int.init) ?? 0)
            }
        }
        center.addObserver(forName: DriverNotification.harnessOpen, object: nil, queue: .main) { [weak self] note in
            let info = Self.strings(note.userInfo)
            MainActor.assumeIsolated {
                self?.startHarness(tag: info["tag"], countdownSeconds: info["countdown"].flatMap(Int.init) ?? 0)
            }
        }
        center.addObserver(forName: DriverNotification.harnessClose, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.harness.close() }
        }
        center.addObserver(forName: DriverNotification.testFields, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.testFields.show() }
        }
        center.addObserver(forName: DriverNotification.liveProvider, object: nil, queue: .main) { [weak self] note in
            let info = Self.strings(note.userInfo)
            MainActor.assumeIsolated { self?.startLiveProviderTest(tag: info["tag"]) }
        }
    }

    nonisolated private static func strings(_ userInfo: [AnyHashable: Any]?) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in userInfo ?? [:] {
            if let key = key as? String, let value = value as? String { result[key] = value }
        }
        return result
    }
}

#endif
