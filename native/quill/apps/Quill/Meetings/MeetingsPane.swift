import MeetingKit
import SwiftUI
import SynthesisKit

/// Settings › Meetings (mockup 6).
struct MeetingsPane: View {
    @Bindable var coordinator: MeetingsCoordinator
    let openFocusEditor: () -> Void
    @State private var confirmingDelete = false
    @State private var meetingCount = 0
    @State private var peopleCount = 0

    static let retentions = [7, 30, 90, 365]

    var body: some View {
        Form {
            Section(MeetingCopy.t("pane.listen")) {
                ForEach(MeetingApp.known.filter { !$0.isBrowser }) { app in
                    Toggle(app.name, isOn: binding(\.offerApps, app.id))
                }
                Toggle(MeetingCopy.t("pane.browsers"), isOn: browsersBinding)
                Text(MeetingCopy.t("pane.offer.help")).font(.caption).foregroundStyle(.secondary)
                Toggle(MeetingCopy.t("pane.microphone"), isOn: bind(\.includeMicrophone))
                Toggle(MeetingCopy.t("pane.livePanel"), isOn: bind(\.showsLivePanel))
                Picker(MeetingCopy.t("pane.language"), selection: bind(\.localeIdentifier)) {
                    ForEach(MeetingPreferences.languages, id: \.self) { id in
                        Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id)
                    }
                }
            }
            Section(MeetingCopy.t("pane.after")) {
                Toggle(MeetingCopy.t("pane.separate"), isOn: bind(\.separateSpeakers))
                Text(MeetingCopy.t("pane.separate.help")).font(.caption).foregroundStyle(.secondary)
                Picker(MeetingCopy.t("pane.defaultFocus"), selection: bind(\.defaultFocusID)) {
                    ForEach(coordinator.store.focuses()) { Text($0.name).tag($0.id) }
                }
                Picker(MeetingCopy.t("pane.model"), selection: Binding(
                    get: { SynthesisModelChoice.matching(coordinator.preferences.modelSelection) ?? .fidelity },
                    set: { choice in
                        coordinator.preferences.model = "\(choice.selection.provider.rawValue):\(choice.selection.model.rawValue)"
                        coordinator.savePreferences()
                    })) {
                    ForEach(SynthesisModelChoice.allCases) { Text("\($0.name) · \($0.costHint)").tag($0) }
                }
                Text(MeetingCopy.t("pane.model.help")).font(.caption).foregroundStyle(.secondary)
            }
            Section(MeetingCopy.t("pane.roles")) {
                LabeledContent(MeetingCopy.t("pane.roles.catalogue")) {
                    Button(MeetingCopy.t("pane.roles.edit"), action: openFocusEditor)
                }
                LabeledContent(String(localized: "pane.people \(peopleCount)", bundle: .localized)) {
                    Button(MeetingCopy.t("pane.people.forget")) {
                        for person in coordinator.store.people() { try? coordinator.store.forget(person: person.id) }
                        refreshCounts()
                    }
                    .disabled(peopleCount == 0)
                }
            }
            Section(MeetingCopy.t("pane.history")) {
                Picker(MeetingCopy.t("pane.retention"), selection: bind(\.retentionDays)) {
                    ForEach(Self.retentions, id: \.self) { days in
                        Text(String(localized: "pane.retention.days \(days)", bundle: .localized)).tag(days)
                    }
                }
                LabeledContent(String(localized: "pane.history.count \(meetingCount)", bundle: .localized)) {
                    Button(MeetingCopy.t("pane.history.delete"), role: .destructive) { confirmingDelete = true }
                        .disabled(meetingCount == 0)
                }
                Text(MeetingCopy.t("pane.history.help")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshCounts)
        .alert(MeetingCopy.t("history.deleteAll.title"), isPresented: $confirmingDelete) {
            Button(MeetingCopy.t("history.deleteAll.confirm"), role: .destructive) {
                try? coordinator.store.deleteHistory()
                coordinator.meetingChanged()
                refreshCounts()
            }
        }
    }

    private func refreshCounts() {
        meetingCount = coordinator.store.summaries().count
        peopleCount = coordinator.store.people().count
    }

    private func bind<Value>(_ path: WritableKeyPath<MeetingPreferences, Value>) -> Binding<Value> {
        Binding(get: { coordinator.preferences[keyPath: path] },
                set: { coordinator.preferences[keyPath: path] = $0; coordinator.savePreferences() })
    }

    /// One switch for every browser: Meet runs in whichever the user has.
    private var browsersBinding: Binding<Bool> {
        let browsers = Set(MeetingApp.known.filter(\.isBrowser).map(\.id))
        return Binding(get: { !coordinator.preferences.offerApps.isDisjoint(with: browsers) },
                       set: { on in
                           if on { coordinator.preferences.offerApps.formUnion(browsers) }
                           else { coordinator.preferences.offerApps.subtract(browsers) }
                           coordinator.savePreferences()
                       })
    }

    private func binding(_ path: WritableKeyPath<MeetingPreferences, Set<String>>, _ id: String) -> Binding<Bool> {
        Binding(get: { coordinator.preferences[keyPath: path].contains(id) },
                set: { on in
                    if on { coordinator.preferences[keyPath: path].insert(id) } else { coordinator.preferences[keyPath: path].remove(id) }
                    coordinator.savePreferences()
                })
    }
}
