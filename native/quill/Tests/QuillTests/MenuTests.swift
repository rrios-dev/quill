import AppCore
import AppKit
import Carbon.HIToolbox
import Foundation
import ModelKit
import RewriteKit
import Testing

@testable import Quill

@Suite("Hot key controller")
@MainActor
struct HotKeyControllerTests {
    final class Recorder {
        var registrations: [KeyCombination] = []
        var removed: [UInt32] = []
    }

    private func controller(_ recorder: Recorder, answer: @escaping (Int) -> Result<UInt32, HotKeyRegistrationError>)
        -> HotKeyController
    {
        HotKeyController(
            register: { combination, _ in
                recorder.registrations.append(combination)
                return answer(recorder.registrations.count)
            },
            unregister: { recorder.removed.append($0) })
    }

    @Test("an exclusive owner is reported as in use, and no shared registration follows")
    func inUseIsReportedWithoutFallback() {
        let recorder = Recorder()
        let hotKey = controller(recorder) { _ in .failure(HotKeyRegistrationError(status: OSStatus(eventHotKeyExistsErr))) }
        hotKey.register(HotKeyController.defaultShortcut) {}
        #expect(hotKey.state == .inUse(HotKeyController.defaultShortcut))
        #expect(recorder.registrations.count == 1)
        #expect(hotKey.problem?.contains(HotKeyController.defaultShortcut.displayString) == true)
    }

    @Test("a free combination registers, and re-registering removes the previous one")
    func registersAndReplaces() {
        let recorder = Recorder()
        let hotKey = controller(recorder) { .success(UInt32($0)) }
        hotKey.register(HotKeyController.defaultShortcut) {}
        #expect(hotKey.state == .registered(HotKeyController.defaultShortcut))
        #expect(hotKey.problem == nil)
        let other = KeyCombination(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | cmdKey))
        hotKey.register(other) {}
        #expect(recorder.removed == [1])
        #expect(hotKey.state == .registered(other))
    }

    @Test("any other refusal is a failure with its status")
    func otherFailure() {
        let recorder = Recorder()
        let hotKey = controller(recorder) { _ in .failure(HotKeyRegistrationError(status: OSStatus(eventHotKeyInvalidErr))) }
        hotKey.register(HotKeyController.defaultShortcut) {}
        #expect(hotKey.state == .failed(HotKeyController.defaultShortcut, OSStatus(eventHotKeyInvalidErr)))
        #expect(hotKey.problem != nil)
    }

    @Test("the default shortcut is ⌃⌥R (README Q4)")
    func defaultShortcut() {
        #expect(HotKeyController.defaultShortcut.displayString == "⌃⌥R")
    }
}

@Suite("Permission watcher")
@MainActor
struct PermissionWatcherTests {
    @Test("a grant that arrives while running asks for a restart")
    func grantWhileRunning() {
        var trusted = false
        let watcher = PermissionWatcher(isTrusted: { trusted })
        var changes: [PermissionWatcher.State] = []
        watcher.onChange = { changes.append($0) }
        #expect(watcher.state == .notTrusted)
        watcher.refresh()
        #expect(changes.isEmpty)
        trusted = true
        watcher.refresh()
        #expect(watcher.state == .grantedWhileRunning)
        watcher.refresh()
        #expect(changes == [.grantedWhileRunning])
    }

    @Test("transitions")
    func transitions() {
        #expect(PermissionWatcher.next(.trusted, trusted: true) == .trusted)
        #expect(PermissionWatcher.next(.trusted, trusted: false) == .notTrusted)
        #expect(PermissionWatcher.next(.notTrusted, trusted: true) == .grantedWhileRunning)
        #expect(PermissionWatcher.next(.grantedWhileRunning, trusted: false) == .notTrusted)
        #expect(PermissionWatcher.next(.grantedWhileRunning, trusted: true) == .grantedWhileRunning)
    }

    @Test("polls every second while the grant is missing, every 15 seconds once it is there")
    func interval() {
        #expect(PermissionWatcher.interval(for: .notTrusted) == 1)
        #expect(PermissionWatcher.interval(for: .trusted) == 15)
        #expect(PermissionWatcher.interval(for: .grantedWhileRunning) == 15)
    }
}

@Suite("Provider status")
struct ProviderStatusTests {
    private let profile = Profile(name: "Work", symbol: "briefcase", settings: ProfileSettings(scope: .rewrite),
                                  model: ModelSelection(provider: "openai", model: "pinned"))

    @Test("the next-rewrite profile's pinned model wins over the global choice")
    func selection() {
        let global = ModelSelection(provider: "openrouter", model: "global")
        var settings = QuillSettings(globalModel: global)
        #expect(ProviderStatus.selection(settings: settings, profiles: [profile]) == global)
        settings.nextRewriteProfile = profile.id
        #expect(ProviderStatus.selection(settings: settings, profiles: [profile])?.model == "pinned")
        settings.nextRewriteProfile = nil
        settings.lastUsedProfile = profile.id
        #expect(ProviderStatus.selection(settings: settings, profiles: [profile])?.model == "pinned")
        #expect(ProviderStatus.selection(settings: QuillSettings(), profiles: []) == nil)
    }

    @Test("a removed key shows on the next evaluation")
    func removedKey() async throws {
        let credentials = InMemoryCredentialStore(["openai": "test-value"])
        let registry = try ProviderRegistry([ChatCompletionsProvider.openAI(credentials: credentials)])
        let selection = ModelSelection(provider: "openai", model: "any")
        #expect(await ProviderStatus.evaluate(selection, registry: registry) == .available(provider: "OpenAI"))
        try credentials.removeSecret(for: "openai")
        #expect(await ProviderStatus.evaluate(selection, registry: registry) == .needsKey(provider: "OpenAI"))
    }

    @Test("no model, or a provider that no longer exists, needs a provider")
    func needsProvider() async throws {
        let registry = try ProviderRegistry([])
        #expect(await ProviderStatus.evaluate(nil, registry: registry) == .needsProvider)
        #expect(await ProviderStatus.evaluate(ModelSelection(provider: "custom-gone", model: "m"), registry: registry)
                == .needsProvider)
    }

    @Test("every status has copy")
    func copy() {
        let all: [ProviderStatus] = [.available(provider: "X"), .needsKey(provider: "X"), .appleIntelligenceOff,
                                     .notSupported(provider: "X"), .preparing(provider: "X"), .needsProvider]
        for status in all { #expect(!status.title.hasPrefix("menu.")) }
    }
}

@Suite("App wiring")
struct AppWiringTests {
    @Test("the Keychain service is fixed; only a suffixed debug bundle id gets its own")
    func keychainService() {
        #expect(AppPaths.keychainService(bundleIdentifier: nil) == "quill.providers")
        #expect(AppPaths.keychainService(bundleIdentifier: AppPaths.defaultBundleIdentifier) == "quill.providers")
        #expect(AppPaths.keychainService(bundleIdentifier: AppPaths.defaultBundleIdentifier + ".walkthrough")
                == "quill.providers.walkthrough")
        #expect(AppPaths.keychainService(bundleIdentifier: "com.example.other") == "quill.providers")
    }

    @Test("built-ins take the first preferred language Quill ships in")
    func profileLanguage() {
        #expect(AppEnvironment.profileLanguage(preferred: ["fr-FR", "es-ES", "en"]) == "es")
        #expect(AppEnvironment.profileLanguage(preferred: ["en-GB"]) == "en")
        #expect(AppEnvironment.profileLanguage(preferred: ["de"]) == "en")
    }

    @Test("the self-check names a missing, an empty and an unloadable bundle")
    func selfCheckBundles() throws {
        let resources = FileManager.default.temporaryDirectory
            .appendingPathComponent("SelfCheckTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: resources) }
        let full = resources.appendingPathComponent("Full.bundle/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: full, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: full.appendingPathComponent("file.json"))
        try FileManager.default.createDirectory(
            at: resources.appendingPathComponent("Empty.bundle/Contents/Resources"), withIntermediateDirectories: true)

        let problems = SelfCheck.bundleProblems(in: resources, required: ["Full", "Missing"])
        #expect(problems.contains("Missing.bundle is missing"))
        #expect(problems.contains("Empty.bundle does not load or is empty"))
        #expect(!problems.contains { $0.hasPrefix("Full") })
        #expect(SelfCheck.bundleProblems(in: nil, required: []) == ["the app has no Resources directory"])
    }

    @Test("built-ins sort first, in PRODUCT's order, then the user's by name")
    func menuOrder() {
        func make(_ name: String, _ builtIn: BuiltInProfile?) -> Profile {
            Profile(name: name, symbol: "x", builtIn: builtIn, settings: ProfileSettings(scope: .rewrite))
        }
        let sorted = [make("Zeta", nil), make("Formal", .formal), make("alpha", nil), make("Spelling", .spelling)]
            .sorted(by: AppDelegate.menuOrder).map(\.name)
        #expect(sorted == ["Spelling", "Formal", "alpha", "Zeta"])
    }
}

@Suite("Brand mark")
@MainActor
struct BrandMarkTests {
    @Test("the menu bar mark is an 18-point template image with ink in it")
    func menuBarMark() throws {
        let image = BrandMark.menuBarImage(accessibilityDescription: "Quill")
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()
        var inked = 0
        for x in 0..<36 { for y in 0..<36 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked += 1 } }
        #expect((150...900).contains(inked), "\(inked) of 1296 pixels inked: neither empty nor a blot")
        if let path = ProcessInfo.processInfo.environment["QUILL_BRANDMARK_PNG"] {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}

