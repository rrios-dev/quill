import MeetingKit
import SwiftUI

/// Settings › Meetings › Vocabulary (EFFICIENCY.md E6): the words Quill writes its own
/// way, grouped by whose they are, added and changed by hand as well as learnt from
/// corrections. Opens with what the whole holds (C-44), then each owner's words.
struct VocabularySection: View {
    let store: MeetingStore
    let changed: () -> Void
    @State private var entries: [VocabularyEntry] = []
    @State private var people: [Person] = []
    @State private var editing: VocabularyEntry?

    var body: some View {
        Section {
            Text(summary).font(.callout)
            ForEach(groups, id: \.title) { group in
                DisclosureGroup {
                    ForEach(group.entries) { entry in
                        HStack {
                            Text("«\(entry.heard)» → «\(entry.written)»")
                            Spacer()
                            if entry.uses > 1 {
                                Text(String(localized: "pane.vocabulary.uses \(entry.uses)", bundle: .localized))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button { editing = entry } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(String(localized: "pane.vocabulary.edit \(entry.written)", bundle: .localized))
                            Button(role: .destructive) {
                                try? store.forgetVocabulary(entry.id)
                                reload()
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(String(localized: "pane.vocabulary.forget \(entry.written)", bundle: .localized))
                        }
                    }
                } label: {
                    LabeledContent(group.title, value: "\(group.entries.count)")
                }
            }
            Button(MeetingCopy.t("pane.vocabulary.add")) {
                editing = VocabularyEntry(heard: "", written: "", scope: .global, uses: 0)
            }
        } header: {
            Text(MeetingCopy.t("pane.vocabulary"))
        } footer: {
            Text(MeetingCopy.t("pane.vocabulary.help")).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
        .sheet(item: $editing) { entry in
            VocabularyEditor(entry: entry, owners: owners) { saved in
                try? store.setVocabulary(saved)
                editing = nil
                reload()
            } cancel: {
                editing = nil
            }
        }
    }

    private func reload() {
        entries = store.vocabulary()
        people = store.people()
        changed()
    }

    /// "12 words: 3 for everybody, 4 yours, 5 of Fran and Lucía."
    private var summary: String {
        guard !entries.isEmpty else { return MeetingCopy.t("pane.vocabulary.empty") }
        let owners = groups.map { "\($0.title): \($0.entries.count)" }.joined(separator: " · ")
        return String(localized: "pane.vocabulary.summary \(entries.count) \(owners)", bundle: .localized)
    }

    private var groups: [(title: String, entries: [VocabularyEntry])] {
        func sorted(_ list: [VocabularyEntry]) -> [VocabularyEntry] {
            list.sorted { $0.written.localizedCompare($1.written) == .orderedAscending }
        }
        var result: [(String, [VocabularyEntry])] = []
        let global = entries.filter { $0.scope == .global }
        if !global.isEmpty { result.append((MeetingCopy.t("pane.vocabulary.global"), sorted(global))) }
        let mine = entries.filter { $0.scope == .me }
        if !mine.isEmpty { result.append((MeetingCopy.t("pane.vocabulary.me"), sorted(mine))) }
        for owner in owners.filter({ if case .person = $0.scope { return true } else { return false } }) {
            let theirs = entries.filter { $0.scope == owner.scope }
            if !theirs.isEmpty { result.append((owner.title, sorted(theirs))) }
        }
        let known = Set(people.map(\.id))
        let orphans = entries.filter { if case .person(let id) = $0.scope { return !known.contains(id) } else { return false } }
        if !orphans.isEmpty { result.append((MeetingCopy.t("pane.vocabulary.forgotten"), sorted(orphans))) }
        let pending = entries.filter { if case .voice = $0.scope { return true } else { return false } }
        if !pending.isEmpty { result.append((MeetingCopy.t("pane.vocabulary.pending"), sorted(pending))) }
        return result
    }

    /// Whose words an entry can be: everybody, the user, each person (with their role
    /// when two share a name).
    private var owners: [VocabularyEditor.Owner] {
        let roles = Dictionary(store.roles().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let counts = Dictionary(grouping: people, by: { MeetingStore.fold($0.name) }).mapValues(\.count)
        let persons = people.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }.map { person in
            let shared = (counts[MeetingStore.fold(person.name)] ?? 0) > 1
            let role = person.roleID.flatMap { roles[$0] }
            let title = shared ? person.name + " · " + (role ?? person.lastSeen.formatted(date: .abbreviated, time: .omitted)) : person.name
            return VocabularyEditor.Owner(scope: .person(person.id), title: title)
        }
        return [VocabularyEditor.Owner(scope: .global, title: MeetingCopy.t("pane.vocabulary.global")),
                VocabularyEditor.Owner(scope: .me, title: MeetingCopy.t("pane.vocabulary.me"))] + persons
    }
}

/// Adding or changing one word: what Quill hears, how it is written, and whose it is.
struct VocabularyEditor: View {
    struct Owner: Hashable {
        let scope: VocabularyEntry.Scope
        let title: String
    }

    @State var entry: VocabularyEntry
    let owners: [Owner]
    let save: (VocabularyEntry) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(MeetingCopy.t(entry.uses == 0 ? "pane.vocabulary.add" : "pane.vocabulary.change")).font(.headline)
            Form {
                TextField(MeetingCopy.t("pane.vocabulary.heard"), text: $entry.heard,
                          prompt: Text(MeetingCopy.t("pane.vocabulary.heard.prompt")))
                TextField(MeetingCopy.t("pane.vocabulary.written"), text: $entry.written,
                          prompt: Text(MeetingCopy.t("pane.vocabulary.written.prompt")))
                Picker(MeetingCopy.t("pane.vocabulary.owner"), selection: $entry.scope) {
                    ForEach(owners, id: \.scope) { Text($0.title).tag($0.scope) }
                    if !owners.contains(where: { $0.scope == entry.scope }) {
                        Text(MeetingCopy.t("pane.vocabulary.pending")).tag(entry.scope)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(MeetingCopy.t("pane.vocabulary.cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(MeetingCopy.t("pane.vocabulary.save")) {
                    var saved = entry
                    if saved.uses == 0 { saved.uses = 1 }
                    save(saved)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(entry.heard.trimmingCharacters(in: .whitespaces).isEmpty
                          || entry.written.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
