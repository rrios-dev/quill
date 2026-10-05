import AppKit
import GlassUI
import Observation
import QuillSupport
import RewriteKit
import SwiftUI

/// Settings → Apps (PRODUCT F2, §4.1): which profile each app starts with, and whether it
/// applies directly. Deleting a profile removes its mappings (`QuillSettings.forgetProfile`).
@MainActor
@Observable
final class AppsPaneModel {
    struct Row: Identifiable, Equatable {
        var id: String { bundleIdentifier }
        var bundleIdentifier: String
        var name: String
        var profileID: UUID
        var appliesDirectly: Bool
    }

    struct RunningApp: Equatable {
        var bundleIdentifier: String
        var name: String
    }

    private(set) var rows: [Row] = []
    private(set) var profiles: [Profile] = []

    private let settings: SettingsStore
    private let store: ProfileStore
    private let runningApps: @MainActor () -> [RunningApp]
    private let log = QuillLog(category: "apps")

    init(settings: SettingsStore, profiles: ProfileStore, runningApps: @escaping @MainActor () -> [RunningApp] = { AppsPaneModel.liveRunningApps() }) {
        self.settings = settings
        self.store = profiles
        self.runningApps = runningApps
    }

    func reload() {
        profiles = ((try? store.all().profiles) ?? []).sorted(by: AppDelegate.menuOrder)
        let current = (try? settings.settings()) ?? QuillSettings()
        let names = Dictionary(runningApps().map { ($0.bundleIdentifier, $0.name) }, uniquingKeysWith: { first, _ in first })
        rows = current.appDefaults
            .map { bundle, profile in
                Row(bundleIdentifier: bundle, name: names[bundle] ?? Self.name(of: bundle), profileID: profile,
                    appliesDirectly: current.directApplyApps.contains(bundle))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Running apps not mapped yet, to add from (Quill itself excluded).
    var addable: [RunningApp] {
        let mapped = Set(rows.map(\.bundleIdentifier))
        return runningApps()
            .filter { !mapped.contains($0.bundleIdentifier) && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Maps an app to the first profile; the user picks another in its row.
    func add(_ bundleIdentifier: String) {
        guard let first = profiles.first else { return }
        update { $0.appDefaults[bundleIdentifier] = first.id }
    }

    func setProfile(_ profileID: UUID, for bundleIdentifier: String) {
        update { $0.appDefaults[bundleIdentifier] = profileID }
    }

    func setAppliesDirectly(_ on: Bool, for bundleIdentifier: String) {
        update { settings in
            if on { settings.directApplyApps.insert(bundleIdentifier) } else { settings.directApplyApps.remove(bundleIdentifier) }
        }
    }

    func remove(_ bundleIdentifier: String) {
        update { settings in
            settings.appDefaults[bundleIdentifier] = nil
            settings.directApplyApps.remove(bundleIdentifier)
        }
    }

    private func update(_ change: (inout QuillSettings) -> Void) {
        do {
            try settings.update(change)
        } catch {
            log.error("could not save the app mapping: \(error)")
        }
        reload()
    }

    static func liveRunningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let bundle = app.bundleIdentifier else { return nil }
            return RunningApp(bundleIdentifier: bundle, name: app.localizedName ?? bundle)
        }
    }

    static func name(of bundleIdentifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return bundleIdentifier }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

struct AppsPane: View {
    let model: AppsPaneModel

    var body: some View {
        Form {
            Section {
                ForEach(model.rows) { row in
                    HStack {
                        AppIcon(bundleIdentifier: row.bundleIdentifier)
                        Text(row.name)
                        Spacer()
                        Picker(PickerCopy.string("apps.profile"), selection: Binding(
                            get: { row.profileID }, set: { model.setProfile($0, for: row.bundleIdentifier) })) {
                            ForEach(model.profiles) { profile in Text(profile.name).tag(profile.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Toggle(PickerCopy.string("apps.direct"), isOn: Binding(
                            get: { row.appliesDirectly }, set: { model.setAppliesDirectly($0, for: row.bundleIdentifier) }))
                        Button(role: .destructive) { model.remove(row.bundleIdentifier) } label: { Image(systemName: "minus.circle").frame(width: 20, height: 20) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(PickerCopy.string("apps.remove"))
                    }
                }
                if model.rows.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 28)).foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text(PickerCopy.string("apps.empty")).font(.body.weight(.medium))
                        Text(PickerCopy.string("apps.empty.note")).font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Metrics.Spacing.regular)
                }
            } footer: {
                Text(PickerCopy.string("apps.direct.explanation")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Menu {
                    ForEach(model.addable, id: \.bundleIdentifier) { app in
                        Button { model.add(app.bundleIdentifier) } label: {
                            Label { Text(app.name) } icon: { Image(nsImage: AppIcon.image(for: app.bundleIdentifier)) }
                        }
                    }
                } label: {
                    Label(PickerCopy.string("apps.add"), systemImage: "plus")
                }
                .fixedSize()
            }
        }
        .formStyle(.grouped)
        .onAppear { model.reload() }
    }
}

/// An app's own icon, the way Finder shows it.
private struct AppIcon: View {
    let bundleIdentifier: String

    var body: some View {
        Image(nsImage: Self.image(for: bundleIdentifier))
            .resizable()
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }

    static func image(for bundleIdentifier: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}
