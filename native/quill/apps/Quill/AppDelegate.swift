import AppCore
import AppKit
import QuillSupport
import RewriteKit
import SelectionKit

/// The menu bar agent: owns the status item, its menu, the hot key and the permission
/// watcher (ARCHITECTURE §5.1).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var environment: AppEnvironment?
    private let hotKey = HotKeyController()
    private let permission = PermissionWatcher()
    private let log = QuillLog(category: "app")
    /// The provider line's evaluation for the menu that is open, cancelled when it closes.
    private var statusTask: Task<Void, Never>?
    #if DEBUG
    private var debugMenu: DebugMenu?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment()
        self.environment = environment
        NSApplication.shared.mainMenu = EditMenu.makeMainMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = BrandMark.menuBarImage(accessibilityDescription: QuillSupport.productName)
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        // Rebuilt every time it opens, so status lines read the system's current answer
        // rather than the one from launch.
        menu.delegate = self
        item.menu = menu
        statusItem = item
        #if DEBUG
        debugMenu = DebugMenu(statusItem: item)
        #endif

        registerShortcut()
        permission.start()
        showOnboardingIfNeeded()
        services.onText = { [weak self] text in self?.rewriteFromServices(text) }
        NSApplication.shared.servicesProvider = services
        NSUpdateDynamicServices()
        // A process that quits forgets its accessibility switches: a new one with the
        // same pid starts unswitched.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.selection?.processTerminated(pid) }
        }
        #if DEBUG
        listenForMenuDump()
        if DebugHooks.dumpsAccessibility || DebugHooks.snapshotsPicker { Task { await dumpAccessibility() } }
        #endif
    }

    #if DEBUG
    /// `QUILL_DUMP_A11Y`: every surface in turn — the onboarding steps, the Settings panes,
    /// the picker in its main states — then quit. Run with an empty `QUILL_DATA_DIR`, so
    /// onboarding opens. The toast is not walked: it ignores the mouse, so hit-testing
    /// passes through it; it announces its line to VoiceOver instead.
    private func dumpAccessibility() async {
        func settle() async { try? await Task.sleep(for: .milliseconds(900)) }
        await settle()
        let snapshots = DebugHooks.snapshotsPicker
        if !snapshots, let onboarding {
            for step in onboarding.model.steps {
                await settle()
                if let window = onboarding.shownWindow { AccessibilityDump.dump(window, surface: "onboarding.\(step.rawValue)") }
                onboarding.model.next()
            }
            onboarding.shownWindow?.close()
        }
        for pane in [SettingsPane.general, .providers, .profiles, .apps, .about] {
            openSettings(pane)
            await settle()
            await settle()
            guard let window = settingsWindow?.shownWindow else { continue }
            if snapshots {
                print("SNAP settings.\(pane.rawValue) \(window.windowNumber)")
                fflush(stdout)
                try? await Task.sleep(for: .seconds(2))
                if pane == .providers {
                    NotificationCenter.default.post(name: ProvidersPane.debugBrowse, object: nil)
                    await settle()
                    if let sheet = window.attachedSheet {
                        print("SNAP settings.browser \(sheet.windowNumber)")
                        fflush(stdout)
                        try? await Task.sleep(for: .seconds(2))
                        window.endSheet(sheet)
                    }
                }
            } else {
                AccessibilityDump.dump(window, surface: "settings.\(pane.rawValue)")
            }
        }
        settingsWindow?.shownWindow?.close()

        guard let environment, let session = try? makeSession(environment: environment) else {
            print("A11Y ERROR picker: no session")
            exit(1)
        }
        let original = "hola juan, mañana no voy a poder ir a la reunion xq tengo medico a las 10, lo vemos el jueves?"
        let rewritten = "Hola, Juan. Mañana no podré ir a la reunión porque tengo médico a las 10. ¿Lo vemos el jueves?"
        let capture = Capture(text: snapshots ? original : "hello john", app: AppIdentity(pid: 0, bundleIdentifier: nil),
                              editability: snapshots ? .editable : .uncertain, formatting: .plain, method: .accessibility)
        let states: [(String, SessionState)] = [
            ("ready", .ready(text: snapshots ? rewritten : "Hello John.")),
            ("generating", .generating(partial: snapshots ? String(rewritten.prefix(46)) : "Hello")),
            ("noChanges", .noChanges),
            ("flagged", .flagged(text: "Dear [Name], hello John.", flags: [.inventedPlaceholder(["[Name]"]), .addedGreeting])),
            ("consent", .awaitingConsent(ConsentNotice(provider: "openrouter", providerName: "OpenRouter",
                                                       recipients: [.named("OpenRouter"), .routedInferenceProvider],
                                                       firstUseOfProvider: true, profileTextToNewRecipient: false, largeText: nil))),
            ("correcting", .correcting(Correction(text: "Hello John.", saveAsExample: false, saveDisabledReason: nil,
                                                  pending: nil, previous: .ready("Hello John.")))),
            ("failed", .failed(.provider(.unavailable(.missingCredential)), partial: "")),
            ("refused", .refusedCapture(.notTrusted)),
        ]
        for (name, state) in states {
            session.debugPresent(state, capture: capture)
            let picker = PickerController(session: session)
            picker.show()
            await settle()
            if snapshots, let window = picker.window {
                print("SNAP \(name) \(window.windowNumber)")
                fflush(stdout)
                try? await Task.sleep(for: .seconds(2))
            } else if let window = picker.window {
                AccessibilityDump.dump(window, surface: "picker.\(name)")
            }
            picker.close()
        }
        if snapshots {
            // The instruction typed, before Return sends it.
            session.debugPresent(.ready(text: rewritten), capture: capture)
            session.instructionDraft = "hazlo más corto y cordial"
            let picker = PickerController(session: session)
            picker.show()
            await settle()
            if let window = picker.window { print("SNAP instruction \(window.windowNumber)"); fflush(stdout) }
            try? await Task.sleep(for: .seconds(2))
            picker.close()
        }
        print("A11Y DONE")
        fflush(stdout)
        exit(0)
    }
    #endif

    #if DEBUG
    /// `spike-driver.swift menu`: builds the status menu with the same code that fills
    /// it on opening and writes its titles to `probe/menu.txt` — a script cannot open a
    /// status-bar menu without taking the screen (debug builds only).
    static let menuDumpNotification = Notification.Name("dev.rrios.quill.debug.menu.dump")

    static let sessionDumpNotification = Notification.Name("dev.rrios.quill.debug.session.dump")

    private func listenForMenuDump() {
        DistributedNotificationCenter.default().addObserver(
            forName: Self.menuDumpNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dumpMenu() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Self.sessionDumpNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dumpSession() }
        }
        // `spike-driver.swift onboarding [next…]`: walks the first run without clicks.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.rrios.quill.debug.onboarding"), object: nil, queue: .main
        ) { [weak self] note in
            let action = note.userInfo?["action"] as? String
            MainActor.assumeIsolated { self?.driveOnboarding(action) }
        }
        // `spike-driver.swift first-token`: the on-device first token, cold and prewarmed.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.rrios.quill.debug.perf.firstToken"), object: nil, queue: .main
        ) { _ in
            Task { await FirstTokenProbe.run() }
        }
        // `spike-driver.swift settings`: opens Settings, as the menu item does.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.rrios.quill.debug.settings.open"), object: nil, queue: .main
        ) { [weak self] note in
            let pane = (note.userInfo?["pane"] as? String).flatMap(SettingsPane.init(rawValue:))
            MainActor.assumeIsolated { self?.openSettings(pane) }
        }
    }

    /// `spike-driver.swift picker`: the session's state and the picker's window, without
    /// any user text (debug builds only).
    private func dumpSession() {
        let lines: [String] = if let session {
            [
                "state: \(Self.stateName(session.state))",
                "profile: \(session.profile?.name ?? "-")",
                "capture: \(session.capture.map { "\($0.method) \($0.editability) \($0.formatting) element \($0.element != nil) characters \($0.text.count)" } ?? "-")",
                "picker shown: \(picker?.isShown ?? false)",
                "picker key: \(picker?.isKey ?? false)",
                "diff: \(session.showsDiff)",
                "geometry: \(picker?.geometry ?? "-")",
                "timings: capture→picker \(session.timings.captureToPicker.map { String(format: "%.1f", $0) } ?? "-") ms · first token \(session.timings.firstToken.map { String(format: "%.0f", $0) } ?? "-") ms · replace \(session.timings.replace.map { String(format: "%.0f", $0) } ?? "-") ms",
            ]
        } else {
            ["state: none"] + (lastTimings.map { timings in
                ["last timings: capture→picker \(timings.captureToPicker.map { String(format: "%.1f", $0) } ?? "-") ms · first token \(timings.firstToken.map { String(format: "%.0f", $0) } ?? "-") ms · replace \(timings.replace.map { String(format: "%.0f", $0) } ?? "-") ms"]
            } ?? [])
        }
        let url = AppPaths.current.appendingPathComponent("probe/session.txt")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func driveOnboarding(_ action: String?) {
        guard let onboarding else {
            try? "step: none\n".write(to: AppPaths.current.appendingPathComponent("probe/onboarding.txt"), atomically: true, encoding: .utf8)
            return
        }
        switch action {
        case "next": onboarding.model.next()
        case "back": onboarding.model.back()
        default: break
        }
        let model = onboarding.model
        let lines = [
            "step: \(model.current.rawValue)",
            "steps: \(model.steps.map(\.rawValue).joined(separator: ","))",
            "permission: \(model.permission)",
            "clipboard: \(model.clipboardAccess.rawValue)",
            "provider default: \(model.providerDefault)",
            "on-device label: \(model.onDeviceLabel.rawValue)",
            "shown: \(onboarding.isShown)",
        ]
        let url = AppPaths.current.appendingPathComponent("probe/onboarding.txt")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func stateName(_ state: SessionState) -> String {
        switch state {
        case .refusedCapture(let refusal): "refusedCapture(\(refusal))"
        case .failed(let failure, _): "failed(\(failure))"
        case .applied(let outcome): "applied(\(outcome))"
        case .flagged(_, let flags): "flagged(\(flags.map(\.guardID)))"
        default: "\(state)".prefix { $0 != "(" }.description
        }
    }

    private func dumpMenu() {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        let task = statusTask
        Task { [weak self] in
            await task?.value
            let lines = menu.items.map { item -> String in
                if item.isSeparatorItem { return "—" }
                let state = item.state == .on ? "✓ " : ""
                let indent = String(repeating: "  ", count: item.indentationLevel)
                return indent + state + item.title + (item.isEnabled ? "" : "  (disabled)")
            }
            let url = AppPaths.current.appendingPathComponent("probe/menu.txt")
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self?.log.error("menu dump failed: \(error)")
            }
        }
    }
    #endif

    private func registerShortcut() {
        let stored = (try? environment?.settings.settings())?.shortcut
        let combination = stored.map(KeyCombination.init) ?? HotKeyController.defaultShortcut
        hotKey.register(combination) { [weak self] in self?.rewriteSelection() }
        if let problem = hotKey.problem { log.error("shortcut: \(problem)") }
    }

    // MARK: Rewrite

    private var session: RewriteSession?
    private var picker: PickerController?
    private var selection: LiveSessionSelection?
    private var selectionSwitches: KillSwitches?
    private var engine: (GenerationEngine, OutputGuards)?
    private let toast = ToastController()
    /// The last closed session's ARCHITECTURE §11 timings, for the debug dump.
    private var lastTimings: RewriteSession.Timings?

    private let services = ServicesProvider()

    /// Services → "Rewrite with Quill": the same session, started from the delivered
    /// text. Hosted models wait for Return (`RewriteSession`), so another process
    /// calling the service cannot spend the user's key unattended.
    private func rewriteFromServices(_ text: String) {
        guard let environment, let app = NSWorkspace.shared.frontmostApplication else { return }
        if let session, !session.state.isTerminal { return }
        let identity = AppIdentity(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier)
        let operations = SelectionOperations(
            accessibility: LiveAccessibilityClient(), pasteboard: LivePasteboardClient(), keys: LiveKeyEventPoster())
        let height = NSScreen.screens.first?.frame.height ?? 0
        do {
            let session = try makeSession(environment: environment)
            attach(session)
            Task {
                // Right after the handler returns, the host is still finishing the service
                // call and may not answer accessibility yet (measured in TextEdit, P3-T6):
                // a few short retries before settling for "uncertain".
                var result = ServicesProvider.capture(text: text, app: identity, operations: operations, primaryScreenHeight: height)
                for _ in 0..<5 {
                    guard case .success(let capture) = result, capture.element == nil else { break }
                    try? await Task.sleep(for: .milliseconds(100))
                    result = ServicesProvider.capture(text: text, app: identity, operations: operations, primaryScreenHeight: height)
                }
                switch result {
                case .success(let capture): await session.start(.services(capture))
                case .failure(let refusal): session.showRefusal(refusal)
                }
            }
        } catch {
            log.error("could not start a rewrite from Services: \(error)")
        }
    }

    private func attach(_ session: RewriteSession) {
        let picker = PickerController(session: session)
        self.session = session
        self.picker = picker
        selection?.orderOutPicker = { [weak picker] in picker?.orderOut() }
        picker.onClosed = { [weak self, weak session] in
            if let session { self?.lastTimings = session.timings }
            if self?.session === session { self?.session = nil; self?.picker = nil }
        }
        session.onEffect = { [weak self, weak picker] effect in self?.perform(effect, picker: picker) }
    }

    /// The shortcut, or the menu's "Rewrite Selection". With a session open, the
    /// shortcut belongs to it (PRODUCT §4.1's last column: cancel, close).
    @objc private func rewriteSelection() {
        log.info("rewrite requested")
        if let session, !session.state.isTerminal {
            Task { await session.handle(.shortcut) }
            return
        }
        guard let environment, let app = NSWorkspace.shared.frontmostApplication else { return }
        do {
            let session = try makeSession(environment: environment)
            attach(session)
            let identity = AppIdentity(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier)
            let hotKeyCode = hotKey.combination.map { CGKeyCode($0.keyCode) }
            Task { await session.start(.hotKey(app: identity, hotKeyCode: hotKeyCode)) }
        } catch {
            log.error("could not start a rewrite: \(error)")
        }
    }

    private func makeSession(environment: AppEnvironment) throws -> RewriteSession {
        let settings = (try? environment.settings.settings()) ?? QuillSettings()
        if selection == nil || selectionSwitches != settings.killSwitches {
            selection = LiveSessionSelection.live(settings: settings.killSwitches)
            selectionSwitches = settings.killSwitches
        }
        if engine == nil { engine = (try GenerationEngine(), try OutputGuards()) }
        guard let selection, let (engine, guards) = engine else { throw ProfileStoreError.importUnreadable("engine") }
        return RewriteSession(
            settings: environment.settings, profiles: environment.profiles, registry: environment.registry,
            engine: engine, guards: guards, selection: selection,
            catalog: LiveModelCatalog(registry: environment.registry, listCache: environment.modelCache),
            examples: StoreExampleSink(profiles: environment.profiles),
            treatLoopbackAsRemote: DebugHooks.treatsLoopbackAsRemote)
    }

    private func perform(_ effect: SessionEffect, picker: PickerController?) {
        switch effect {
        case .showPicker:
            picker?.show()
        case .close:
            picker?.close()
        case .toast(let outcome, let profile, let direct):
            log.info("applied: \(outcome)\(direct ? " directly" : "")")
            toast.show(ToastController.text(for: outcome, profile: profile, direct: direct),
                       near: session?.capture?.bounds)
        case .openSettings(let pane):
            switch pane {
            case .providers: openSettings(.providers)
            }
        case .openAccessibilitySettings:
            NSWorkspace.shared.open(PermissionWatcher.settingsURL)
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        permission.refresh()

        let rewrite = NSMenuItem(
            title: String(localized: "menu.rewrite", bundle: .localized),
            action: #selector(rewriteSelection), keyEquivalent: "")
        rewrite.target = self
        if let combination = hotKey.combination, hotKey.problem == nil {
            rewrite.title += "  " + combination.displayString
        }
        menu.addItem(rewrite)
        if let problem = hotKey.problem { menu.addItem(Self.note(problem)) }

        addPermissionItems(to: menu)
        addProfileItems(to: menu)

        menu.addItem(.separator())
        let status = Self.note(String(localized: "menu.status.checking", bundle: .localized))
        menu.addItem(status)
        refreshStatus(status)

        menu.addItem(.separator())
        let settings = NSMenuItem(
            title: String(localized: "menu.settings", bundle: .localized), action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(
            title: String(localized: "menu.about \(QuillSupport.productName)", bundle: .localized),
            action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        #if DEBUG
        if let debugMenu {
            menu.addItem(.separator())
            menu.addItem(debugMenu.makeItem())
        }
        #endif
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: String(localized: "menu.quit \(QuillSupport.productName)", bundle: .localized),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusTask?.cancel()
        statusTask = nil
    }

    private func addPermissionItems(to menu: NSMenu) {
        switch permission.state {
        case .trusted:
            break
        case .notTrusted:
            let allow = NSMenuItem(
                title: String(localized: "menu.permission.allow", bundle: .localized),
                action: #selector(openAccessibilitySettings), keyEquivalent: "")
            allow.target = self
            menu.addItem(allow)
        case .grantedWhileRunning:
            let restart = NSMenuItem(
                title: String(localized: "menu.permission.restart \(QuillSupport.productName)", bundle: .localized),
                action: #selector(restart), keyEquivalent: "")
            restart.target = self
            menu.addItem(restart)
        }
    }

    /// The quick profile list: sets the profile for the next rewrite only.
    private func addProfileItems(to menu: NSMenu) {
        guard let environment, let profiles = try? environment.profiles.all().profiles, !profiles.isEmpty else { return }
        let next = (try? environment.settings.settings())?.nextRewriteProfile
        menu.addItem(.separator())
        menu.addItem(Self.note(String(localized: "menu.nextRewrite", bundle: .localized)))
        for profile in profiles.sorted(by: Self.menuOrder) {
            let item = NSMenuItem(title: profile.name, action: #selector(chooseNextProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            item.image = NSImage(systemSymbolName: profile.symbol, accessibilityDescription: nil)
            item.state = profile.id == next ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }
    }

    /// Built-ins first in PRODUCT §5's order, then the user's, by name.
    nonisolated static func menuOrder(_ lhs: Profile, _ rhs: Profile) -> Bool {
        let order = BuiltInProfile.allCases
        switch (lhs.builtIn.flatMap(order.firstIndex), rhs.builtIn.flatMap(order.firstIndex)) {
        case let (left?, right?): return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Fills the provider line once the provider has answered. Each opening asks again.
    private func refreshStatus(_ item: NSMenuItem) {
        statusTask?.cancel()
        guard let environment else { return }
        let settings = (try? environment.settings.settings()) ?? QuillSettings()
        let profiles = (try? environment.profiles.all().profiles) ?? []
        let selection = ProviderStatus.selection(settings: settings, profiles: profiles)
        let registry = environment.registry.current
        statusTask = Task { [weak item] in
            let status = await ProviderStatus.evaluate(selection, registry: registry)
            guard !Task.isCancelled else { return }
            item?.title = status.title
        }
    }

    static func note(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func chooseNextProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        do {
            try environment?.settings.update { $0.nextRewriteProfile = $0.nextRewriteProfile == id ? nil : id }
        } catch {
            log.error("could not save the next-rewrite profile: \(error)")
        }
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(PermissionWatcher.settingsURL)
    }

    @objc private func restart() {
        PermissionWatcher.restart()
    }

    private var settingsWindow: SettingsWindowController?

    @objc private func openSettingsFromMenu() { openSettings(nil) }

    private func makeGeneralModel(_ environment: AppEnvironment) -> GeneralPaneModel {
        GeneralPaneModel(
            settings: environment.settings, dataDirectory: environment.dataDirectory,
            credentials: environment.credentials,
            registerShortcut: { [weak self] combination in
                guard let self else { return nil }
                hotKey.register(combination) { [weak self] in self?.rewriteSelection() }
                return hotKey.problem
            },
            afterReset: { PermissionWatcher.restart() })
    }

    private func makeProvidersModel(_ environment: AppEnvironment) -> ProvidersPaneModel {
        ProvidersPaneModel(
            settings: environment.settings, profiles: environment.profiles, registry: environment.registry,
            credentials: environment.credentials, cache: environment.modelCache, readiness: environment.readiness)
    }

    // MARK: Onboarding

    private var onboarding: OnboardingWindowController?

    /// First run (PRODUCT F4): until it is finished, it opens at launch.
    private func showOnboardingIfNeeded() {
        guard let environment, !((try? environment.settings.settings())?.onboardingCompleted ?? false) else { return }
        let model = OnboardingModel(
            settings: environment.settings, profiles: environment.profiles, registry: environment.registry,
            readiness: environment.readiness, providers: makeProvidersModel(environment),
            relocation: AppRelocation.decide(bundleURL: Bundle.main.bundleURL),
            isTrusted: { AXIsProcessTrusted() },
            readAccess: { LivePasteboardClient().accessBehavior() })
        let controller = OnboardingWindowController(model: model, general: makeGeneralModel(environment))
        controller.onFinished = { [weak self] in self?.onboarding = nil }
        onboarding = controller
        controller.show()
    }

    private func openSettings(_ pane: SettingsPane?) {
        guard let environment else { return }
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                general: makeGeneralModel(environment),
                providers: makeProvidersModel(environment),
                profiles: ProfilesPaneModel(
                    settings: environment.settings, profiles: environment.profiles, registry: environment.registry,
                    catalog: LiveModelCatalog(registry: environment.registry, listCache: environment.modelCache),
                    readiness: environment.readiness,
                    treatLoopbackAsRemote: DebugHooks.treatsLoopbackAsRemote),
                apps: AppsPaneModel(settings: environment.settings, profiles: environment.profiles))
        }
        settingsWindow?.show(pane)
    }

    @objc private func showAbout() {
        NSApplication.shared.activate()
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }
}
