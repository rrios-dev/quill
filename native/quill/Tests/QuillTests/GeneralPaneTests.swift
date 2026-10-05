import AppCore
import AppKit
import Carbon.HIToolbox
import Foundation
import ModelKit
import RewriteKit
import Testing

@testable import Quill

@Suite("General pane", .serialized)
@MainActor
struct GeneralPaneTests {
    private func harness(overrides: [String: Any] = [:]) -> (GeneralPaneModel, SettingsStore, InMemoryCredentialStore, URL, Box) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GeneralPaneTests-\(UUID().uuidString)")
        let settings = SettingsStore(dataDirectory: folder)
        let credentials = InMemoryCredentialStore()
        let box = Box()
        let model = GeneralPaneModel(
            settings: settings, dataDirectory: folder, credentials: credentials,
            systemShortcuts: SystemShortcuts(overrides: overrides),
            registerShortcut: { combination in box.registered.append(combination); return box.problem },
            launchAtLogin: ({ box.loginEnabled }, { box.loginEnabled = $0; return true }),
            afterReset: { box.restarted = true })
        model.reload()
        return (model, settings, credentials, folder, box)
    }

    final class Box {
        var registered: [KeyCombination] = []
        var problem: String?
        var loginEnabled = false
        var restarted = false
    }

    @Test("a system shortcut shows the warning; the default does not")
    func systemWarning() throws {
        let (model, _, _, folder, _) = harness()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(model.systemConflict == nil, "⌃⌥R is free by default")
        model.setShortcut(KeyCombination(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)))
        let warning = try #require(model.systemConflict)
        #expect(warning.contains("Spotlight"))
    }

    @Test("the user's own system shortcuts count, and a disabled default does not")
    func overrides() {
        // The user moved Spotlight (64) to ⌃⌥R and turned Mission Control (32) off.
        let overrides: [String: Any] = [
            "64": ["enabled": 1, "value": ["parameters": [114, 15, Int(NSEvent.ModifierFlags([.control, .option]).rawValue)],
                                          "type": "standard"]],
            "32": ["enabled": 0, "value": ["parameters": [65_535, 126, 8_650_752], "type": "standard"]],
        ]
        let shortcuts = SystemShortcuts(overrides: overrides)
        #expect(shortcuts.conflict(for: HotKeyController.defaultShortcut)?.nameKey == "system.spotlight")
        #expect(shortcuts.conflict(for: KeyCombination(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))) == nil,
                "Spotlight's old combination is free once moved")
        #expect(shortcuts.conflict(for: KeyCombination(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(controlKey))) == nil)
    }

    @Test("Cocoa masks become Carbon modifiers; the function-key bit is dropped")
    func masks() {
        #expect(SystemShortcuts.carbonModifiers(cocoa: 8_650_752) == UInt32(controlKey))
        #expect(SystemShortcuts.carbonModifiers(cocoa: 1_179_648) == UInt32(cmdKey | shiftKey))
    }

    @Test("a new shortcut is saved and registered, and its problem reported")
    func shortcutSaved() throws {
        let (model, settings, _, folder, box) = harness()
        defer { try? FileManager.default.removeItem(at: folder) }
        box.problem = "in use"
        let combination = KeyCombination(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | cmdKey))
        model.setShortcut(combination)
        #expect(box.registered == [combination])
        #expect(model.shortcutProblem == "in use")
        #expect(try settings.settings().shortcut == StoredShortcut(keyCode: combination.keyCode, modifiers: combination.modifiers))
    }

    @Test("kill switches are saved; with the ⌘C fallback off the next session's capture is built without it")
    func killSwitches() throws {
        let (model, settings, _, folder, _) = harness()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.setKillSwitch(\.copyFallback, false)
        model.setKillSwitch(\.enhancedAccessibility, false)
        let stored = try settings.settings().killSwitches
        #expect(!stored.copyFallback && !stored.enhancedAccessibility && stored.manualAccessibility)
        // The live selection is rebuilt from these switches (AppDelegate.makeSession); the
        // capturer then refuses with copyDisabled where accessibility has no text
        // (SelectionKitTests, CaptureTests).
    }

    @Test("launch at login follows the toggle")
    func launchAtLogin() throws {
        let (model, _, _, folder, box) = harness()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.setLaunchesAtLogin(true)
        #expect(box.loginEnabled && model.launchesAtLogin)
    }

    @Test("Reset Quill leaves no files and no keys, then restarts")
    func reset() throws {
        let (model, settings, credentials, folder, box) = harness()
        defer { try? FileManager.default.removeItem(at: folder) }
        model.setKillSwitch(\.copyFallback, false)
        try credentials.setSecret("test-value", for: "openai")
        try model.reset()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(try credentials.secret(for: "openai") == nil)
        #expect(box.restarted)
        #expect(try settings.settings() == QuillSettings())
    }
}
