import AppKit
import GlassUI
import MeetingKit
import Observation
import SwiftUI
import SynthesisKit

/// Focuses and roles (mockup 7): what each focus is for, how each role counts in it,
/// and the role catalogue itself.
@MainActor
final class FocusEditorController {
    private var window: NSWindow?
    private let model: FocusEditorModel

    init(store: MeetingStore, onChange: @escaping () -> Void) {
        model = FocusEditorModel(store: store, onChange: onChange)
    }

    var shownWindow: NSWindow? { window }

    func show() {
        model.reload()
        if window == nil {
            let hosting = NSHostingController(rootView: FocusEditorView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = MeetingCopy.t("focus.window")
            window.setContentSize(NSSize(width: 1000, height: 680))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
@Observable
final class FocusEditorModel {
    enum Selection: Hashable { case focus(String), roles }

    private(set) var focuses: [SynthesisFocus] = []
    var roles: [MeetingRole] = []
    var selection: Selection = .focus("work")
    var draft: SynthesisFocus = .work
    private let store: MeetingStore
    private let onChange: () -> Void

    init(store: MeetingStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
    }

    func reload() {
        focuses = store.focuses()
        roles = store.roles()
        if case .focus(let id) = selection, let focus = focuses.first(where: { $0.id == id }) { draft = focus }
    }

    func select(_ selection: Selection) {
        self.selection = selection
        if case .focus(let id) = selection, let focus = focuses.first(where: { $0.id == id }) { draft = focus }
    }

    func isBuiltIn(_ id: String) -> Bool { SynthesisFocus.builtIns.contains { $0.id == id } }

    func treatment(for role: MeetingRole) -> Treatment { draft.weighting.rule(for: role).treatment }

    func setTreatment(_ treatment: Treatment, for role: MeetingRole) {
        var rule = draft.weighting.rules[role.id] ?? .init(treatment)
        rule.treatment = treatment
        if treatment != .decides { rule.scope = nil }
        draft.weighting.rules[role.id] = rule
        saveDraft()
    }

    func scope(for role: MeetingRole) -> String { draft.weighting.rules[role.id]?.scope ?? "" }

    func setScope(_ scope: String, for role: MeetingRole) {
        draft.weighting.rules[role.id]?.scope = scope.isEmpty ? nil : scope
        saveDraft()
    }

    func saveDraft() {
        try? store.saveFocus(draft)
        focuses = store.focuses()
        onChange()
    }

    func addFocus() {
        let focus = SynthesisFocus(id: "custom-\(UUID().uuidString.prefix(8))", name: MeetingCopy.t("focus.new"),
                                   objective: "", guidance: SynthesisFocus.customGuidance, weighting: SynthesisFocus.work.weighting)
        try? store.saveFocus(focus)
        focuses = store.focuses()
        select(.focus(focus.id))
        onChange()
    }

    /// A built-in returns to how it shipped; a custom one is deleted.
    func removeSelected() {
        guard case .focus(let id) = selection else { return }
        try? store.deleteFocus(id)
        focuses = store.focuses()
        select(.focus(focuses.first?.id ?? "work"))
        onChange()
    }

    func saveRoles() {
        try? store.saveRoles(roles.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty })
        onChange()
    }

    func addRole() {
        roles.append(MeetingRole(id: "role-\(UUID().uuidString.prefix(8))", name: MeetingCopy.t("role.new"), summary: ""))
        saveRoles()
    }

    func removeRole(_ id: String) {
        roles.removeAll { $0.id == id }
        saveRoles()
    }
}

struct FocusEditorView: View {
    @Bindable var model: FocusEditorModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.selection }, set: { if let value = $0 { model.select(value) } })) {
                Section(MeetingCopy.t("focus.list")) {
                    ForEach(model.focuses) { focus in
                        Text(focus.name).tag(FocusEditorModel.Selection.focus(focus.id))
                    }
                }
                Section(MeetingCopy.t("focus.catalogue")) {
                    Label(MeetingCopy.t("focus.roles"), systemImage: "person.2").tag(FocusEditorModel.Selection.roles)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .toolbar {
                ToolbarItem {
                    Button { model.addFocus() } label: { Image(systemName: "plus") }
                        .accessibilityLabel(MeetingCopy.t("focus.add"))
                }
            }
        } detail: {
            switch model.selection {
            case .focus: focusDetail
            case .roles: rolesDetail
            }
        }
    }

    private var focusDetail: some View {
        Form {
            Section {
                TextField(MeetingCopy.t("focus.name"), text: $model.draft.name).onSubmit { model.saveDraft() }
                TextField(MeetingCopy.t("focus.objective"), text: $model.draft.objective).onSubmit { model.saveDraft() }
            }
            Section {
                ForEach(model.roles) { role in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(role.name).font(.system(size: 13, weight: .semibold))
                                Text(role.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .frame(width: 170, alignment: .leading)
                            Picker(role.name, selection: Binding(get: { model.treatment(for: role) },
                                                                 set: { model.setTreatment($0, for: role) })) {
                                ForEach(Treatment.allCases, id: \.self) { Text(MeetingCopy.treatment($0)).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }
                        if model.treatment(for: role) == .decides {
                            TextField(MeetingCopy.t("focus.scope"), text: Binding(get: { model.scope(for: role) },
                                                                                  set: { model.setScope($0, for: role) }))
                                .font(.system(size: 12))
                        }
                    }
                }
                Picker(MeetingCopy.t("focus.fallback"), selection: Binding(get: { model.draft.weighting.fallback },
                                                                           set: { model.draft.weighting.fallback = $0; model.saveDraft() })) {
                    ForEach(Treatment.allCases, id: \.self) { Text(MeetingCopy.treatment($0)).tag($0) }
                }
            } header: {
                Text(MeetingCopy.t("focus.weighting"))
            } footer: {
                Text(MeetingCopy.t("focus.treatments.help")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: $model.draft.notes)
                    .font(.system(size: 13))
                    .frame(minHeight: 110)
                Button(MeetingCopy.t("focus.save")) { model.saveDraft() }
            } header: {
                Text(MeetingCopy.t("focus.guidance"))
            } footer: {
                Text(MeetingCopy.t("focus.guidance.help")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text(MeetingCopy.t("focus.invariants")).font(.system(size: 12)).foregroundStyle(.secondary)
            } header: {
                Text(MeetingCopy.t("focus.invariants.title"))
            }
            Section {
                if case .focus(let id) = model.selection {
                    Button(model.isBuiltIn(id) ? MeetingCopy.t("focus.restore") : MeetingCopy.t("focus.delete"),
                           role: .destructive) { model.removeSelected() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var rolesDetail: some View {
        Form {
            Section {
                ForEach($model.roles) { $role in
                    HStack {
                        TextField(MeetingCopy.t("role.name"), text: $role.name).frame(width: 180)
                        TextField(MeetingCopy.t("role.summary"), text: $role.summary)
                        Button { model.removeRole(role.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(String(localized: "role.remove \(role.name)", bundle: .localized))
                    }
                    .onSubmit { model.saveRoles() }
                }
                Button(MeetingCopy.t("role.add")) { model.addRole() }
            } header: {
                Text(MeetingCopy.t("focus.roles"))
            } footer: {
                Text(MeetingCopy.t("role.help")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
