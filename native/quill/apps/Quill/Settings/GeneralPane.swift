import AppCore
import AppKit
import ModelKit
import Observation
import QuillSupport
import RewriteKit
import SwiftUI

/// Settings → General (PLAN P4-T5): the shortcut with the system-shortcut warning, launch
/// at login, the capture kill switches and "Reset Quill".
@MainActor
@Observable
final class GeneralPaneModel {
    private(set) var shortcut: KeyCombination = HotKeyController.defaultShortcut
    /// What macOS does with the recorded combination, as copy.
    private(set) var systemConflict: String?
    /// "In use by another app", reported by the registration.
    private(set) var shortcutProblem: String?
    private(set) var killSwitches = KillSwitches()
    private(set) var launchesAtLogin = false

    private let settings: SettingsStore
    private let dataDirectory: URL
    private let credentials: any CredentialStore
    private let systemShortcuts: SystemShortcuts
    /// Registers the new shortcut; returns its problem, if any.
    private let registerShortcut: (KeyCombination) -> String?
    private let launchAtLogin: (enabled: () -> Bool, set: (Bool) -> Bool)
    /// After "Reset Quill": the app restarts with nothing.
    private let afterReset: () -> Void
    private let log = QuillLog(category: "general")

    init(settings: SettingsStore, dataDirectory: URL, credentials: any CredentialStore,
         systemShortcuts: SystemShortcuts = .live(),
         registerShortcut: @escaping (KeyCombination) -> String?,
         launchAtLogin: (enabled: () -> Bool, set: (Bool) -> Bool) = ({ LaunchAtLogin.isEnabled }, { LaunchAtLogin.set($0) }),
         afterReset: @escaping () -> Void) {
        self.settings = settings
        self.dataDirectory = dataDirectory
        self.credentials = credentials
        self.systemShortcuts = systemShortcuts
        self.registerShortcut = registerShortcut
        self.launchAtLogin = launchAtLogin
        self.afterReset = afterReset
    }

    func reload() {
        let current = (try? settings.settings()) ?? QuillSettings()
        shortcut = current.shortcut.map(KeyCombination.init) ?? HotKeyController.defaultShortcut
        killSwitches = current.killSwitches
        launchesAtLogin = launchAtLogin.enabled()
        systemConflict = conflictCopy(for: shortcut)
    }

    func setShortcut(_ combination: KeyCombination) {
        shortcut = combination
        systemConflict = conflictCopy(for: combination)
        do {
            try settings.update { $0.shortcut = StoredShortcut(keyCode: combination.keyCode, modifiers: combination.modifiers) }
        } catch {
            log.error("could not save the shortcut: \(error)")
        }
        shortcutProblem = registerShortcut(combination)
    }

    private func conflictCopy(for combination: KeyCombination) -> String? {
        systemShortcuts.conflict(for: combination).map {
            PickerCopy.string("general.shortcut.system \(Presentation.Entry(key: $0.nameKey).text)")
        }
    }

    func setKillSwitch(_ path: WritableKeyPath<KillSwitches, Bool>, _ on: Bool) {
        do {
            try settings.update { $0.killSwitches[keyPath: path] = on }
            killSwitches[keyPath: path] = on
        } catch {
            log.error("could not save the switch: \(error)")
        }
    }

    func setLaunchesAtLogin(_ on: Bool) {
        launchesAtLogin = launchAtLogin.set(on) ? on : launchAtLogin.enabled()
    }

    /// Deletes every file in the data folder and every key of the app's Keychain service
    /// (PRODUCT §7). The view asks first.
    func reset() throws {
        try QuillReset.run(dataDirectory: dataDirectory, credentials: credentials)
        settings.invalidate()
        afterReset()
    }
}

struct GeneralPane: View {
    let model: GeneralPaneModel
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section {
                LabeledContent(PickerCopy.string("general.shortcut.label")) {
                    ShortcutRecorder(combination: Binding(get: { model.shortcut }, set: { model.setShortcut($0) }))
                }
                if let conflict = model.systemConflict {
                    Label(conflict, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let problem = model.shortcutProblem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                Text(PickerCopy.string("general.shortcut.note \(QuillSupport.productName)")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(PickerCopy.string("general.launchAtLogin"), isOn: Binding(
                    get: { model.launchesAtLogin }, set: { model.setLaunchesAtLogin($0) }))
            }
            Section(PickerCopy.string("general.capture")) {
                Toggle(PickerCopy.string("general.copyFallback"), isOn: Binding(
                    get: { model.killSwitches.copyFallback }, set: { model.setKillSwitch(\.copyFallback, $0) }))
                Text(PickerCopy.string("general.copyFallback.note")).font(.caption).foregroundStyle(.secondary)
                Toggle(PickerCopy.string("general.manualAccessibility"), isOn: Binding(
                    get: { model.killSwitches.manualAccessibility }, set: { model.setKillSwitch(\.manualAccessibility, $0) }))
                Toggle(PickerCopy.string("general.enhancedAccessibility"), isOn: Binding(
                    get: { model.killSwitches.enhancedAccessibility }, set: { model.setKillSwitch(\.enhancedAccessibility, $0) }))
            }
            Section {
                Button(PickerCopy.string("general.reset \(QuillSupport.productName)"), role: .destructive) { confirmingReset = true }
            } footer: {
                Text(PickerCopy.string("general.reset.note")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.reload() }
        .alert(PickerCopy.string("general.reset.title \(QuillSupport.productName)"), isPresented: $confirmingReset) {
            Button(PickerCopy.string("general.reset.confirm"), role: .destructive) { try? model.reset() }
            Button(PickerCopy.string("picker.action.cancel"), role: .cancel) {}
        } message: {
            Text(PickerCopy.string("general.reset.note"))
        }
    }
}

/// Settings → About: version, licences and what Quill keeps (PRODUCT §7).
struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "–") (\(info?["CFBundleVersion"] as? String ?? "–"))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    Text(QuillSupport.productName).font(.title2.weight(.semibold))
                    Text(version).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            Section(PickerCopy.string("about.privacy \(QuillSupport.productName)")) {
                ForEach([("about.privacy.local", "internaldrive"), ("about.privacy.network", "arrow.up.forward.app"),
                         ("about.privacy.keys", "key"), ("about.privacy.nothing", "eye.slash")], id: \.0) { key, symbol in
                    Label { Text(Presentation.Entry(key: key).text) } icon: {
                        Image(systemName: symbol).foregroundStyle(.tint)
                    }
                }
            }
            Section(PickerCopy.string("about.licences")) {
                Text(PickerCopy.string("about.licences.body"))
            }
        }
        .formStyle(.grouped)
    }
}
