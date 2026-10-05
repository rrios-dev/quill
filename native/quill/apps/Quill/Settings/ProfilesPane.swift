import AppKit
import ModelKit
import RewriteKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Profiles. Renders `ProfilesPaneModel`.
struct ProfilesPane: View {
    let model: ProfilesPaneModel
    /// For the model browser, shared with Providers & models.
    let providers: ProvidersPaneModel
    @State private var confirmingExport = false
    @State private var readiness: ReadinessLabel = .notEvaluated
    @State private var choosingSymbol = false
    @State private var choosingModel = false

    var body: some View {
        HSplitView {
            list.frame(minWidth: 170, idealWidth: 190, maxWidth: 240)
            Group {
                if model.draft != nil {
                    editor
                } else {
                    Text(PickerCopy.string("profiles.none")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 360)
        }
        .task { await model.reload() }
        .alert(PickerCopy.string("profiles.export.title"), isPresented: $confirmingExport) {
            Button(PickerCopy.string("profiles.export.withSamples")) { export(includeSamples: true) }
            Button(PickerCopy.string("profiles.export.withoutSamples")) { export(includeSamples: false) }
            Button(PickerCopy.string("picker.action.cancel"), role: .cancel) {}
        } message: {
            Text(PickerCopy.string("profiles.export.warning"))
        }
        .alert(PickerCopy.string("providers.notice.title"), isPresented: Binding(
            get: { model.pendingConsent != nil }, set: { if !$0 { model.declineTryItConsent() } })) {
            Button(PickerCopy.string("profiles.tryIt.send")) { Task { await model.acceptTryItConsent() } }
            Button(PickerCopy.string("picker.action.cancel"), role: .cancel) { model.declineTryItConsent() }
        } message: {
            if let notice = model.pendingConsent {
                Text(Presentation.tradeoff(.textLeavesDevice(recipients: notice.recipients)).text)
            }
        }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.selectedID }, set: { id in if let id { Task { await model.select(id) } } })) {
                ForEach(model.profiles) { profile in
                    Label(profile.name, systemImage: profile.symbol).tag(profile.id)
                }
            }
            HStack {
                Button { Task { await model.create(name: PickerCopy.string("profiles.newName")) } } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
                    .accessibilityLabel(PickerCopy.string("profiles.new"))
                Button {
                    if let id = model.selectedID { Task { await model.delete(id) } }
                } label: { Image(systemName: "minus").frame(width: 20, height: 20) }
                    .accessibilityLabel(PickerCopy.string("profiles.delete"))
                    .disabled(model.selectedID == nil)
                Spacer()
                Menu {
                    Button(PickerCopy.string("profiles.export")) { confirmingExport = true }.disabled(model.selectedID == nil)
                    Button(PickerCopy.string("profiles.import")) { importProfile() }
                    Divider()
                    Button(PickerCopy.string("profiles.restore")) { Task { await model.restoreBuiltIns() } }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 20, height: 20) }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(PickerCopy.string("profiles.more"))
            }
            .padding(8)
        }
    }

    // MARK: Editor

    private var editor: some View {
        Form {
            Section {
                TextField(PickerCopy.string("profiles.name"), text: binding(\.name))
                LabeledContent(PickerCopy.string("profiles.symbol")) {
                    Button { choosingSymbol = true } label: {
                        Image(systemName: model.draft?.symbol ?? "pencil")
                            .font(.system(size: 15))
                            .frame(width: 28, height: 22)
                    }
                    .accessibilityLabel(PickerCopy.string("profiles.symbol"))
                    .popover(isPresented: $choosingSymbol, arrowEdge: .trailing) {
                        SymbolGrid(selected: model.draft?.symbol) { symbol in
                            model.draft?.symbol = symbol
                            choosingSymbol = false
                        }
                    }
                }
                LabeledContent(PickerCopy.string("profiles.readiness")) { ReadinessBadge(label: readiness) }
            }
            Section(PickerCopy.string("profiles.settings")) {
                Picker(PickerCopy.string("profiles.scope"), selection: binding(\.settings.scope)) {
                    Text(PickerCopy.string("profiles.scope.spellingOnly")).tag(ProfileSettings.Scope.spellingOnly)
                    Text(PickerCopy.string("profiles.scope.rewrite")).tag(ProfileSettings.Scope.rewrite)
                }
                Picker(PickerCopy.string("profiles.register"), selection: binding(\.settings.register)) {
                    ForEach(ProfileSettings.Register.allCases, id: \.self) { Text(Self.name($0)).tag($0) }
                }
                Picker(PickerCopy.string("profiles.tone"), selection: binding(\.settings.tone)) {
                    ForEach(ProfileSettings.Tone.allCases, id: \.self) { Text(Self.name($0)).tag($0) }
                }
                Picker(PickerCopy.string("profiles.length"), selection: binding(\.settings.length)) {
                    ForEach(ProfileSettings.Length.allCases, id: \.self) { Text(Self.name($0)).tag($0) }
                }
                Toggle(PickerCopy.string("profiles.expandAbbreviations"), isOn: Binding(
                    get: { model.draft?.settings.abbreviations == .expand },
                    set: { model.draft?.settings.abbreviations = $0 ? .expand : .keep }))
                Toggle(PickerCopy.string("profiles.removeInterjections"), isOn: Binding(
                    get: { model.draft?.settings.interjections == .remove },
                    set: { model.draft?.settings.interjections = $0 ? .remove : .keep }))
                Toggle(PickerCopy.string("profiles.removeEmoji"), isOn: Binding(
                    get: { model.draft?.settings.emoji == .remove },
                    set: { model.draft?.settings.emoji = $0 ? .remove : .keep }))
                ForEach(ProfileSettings.Preserved.allCases, id: \.self) { kept in
                    Toggle(Self.name(kept), isOn: Binding(
                        get: { model.draft?.settings.preserve.contains(kept) == true },
                        set: { on in
                            if on { model.draft?.settings.preserve.insert(kept) } else { model.draft?.settings.preserve.remove(kept) }
                        }))
                }
            }
            Section(PickerCopy.string("profiles.model")) {
                LabeledContent(PickerCopy.string("profiles.model")) {
                    HStack(spacing: 8) {
                        Text(pinnedModelName).foregroundStyle(model.draft?.model == nil ? .secondary : .primary).lineLimit(1)
                        if model.draft?.model != nil {
                            Button(PickerCopy.string("profiles.model.useGlobal")) { model.draft?.model = nil }
                        }
                        Button(PickerCopy.string("providers.global.change")) { choosingModel = true }
                    }
                }
            }
            .sheet(isPresented: $choosingModel) {
                ModelBrowser(model: providers, provider: nil, current: model.draft?.model) { selection in
                    model.draft?.model = selection
                }
                .task { await providers.refresh() }
            }
            Section(PickerCopy.string("profiles.guidance")) {
                TextEditor(text: binding(\.guidance)).frame(minHeight: 60)
                if let words = model.marks.guidanceSentWords {
                    Text(PickerCopy.string("profiles.guidance.truncated \(words)")).font(.caption).foregroundStyle(.secondary)
                }
                if model.marks.guidanceSkippedForPersonalData {
                    Text(PickerCopy.string("profiles.guidance.personalData")).font(.caption).foregroundStyle(.orange)
                }
            }
            Section(PickerCopy.string("profiles.examples")) {
                ForEach(model.draft?.examples ?? []) { example in
                    ExampleRow(model: model, example: example)
                }
                AddExampleRow(model: model)
            }
            Section(PickerCopy.string("profiles.samples")) {
                ForEach(model.samples.samples) { sample in
                    SampleRow(model: model, sample: sample)
                }
                AddSampleRow(model: model)
                Button(PickerCopy.string("profiles.tryIt")) { Task { await model.tryIt() } }
                    .disabled(model.samples.samples.isEmpty || model.hasChanges)
                if model.hasChanges {
                    Text(PickerCopy.string("profiles.tryIt.saveFirst")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(PickerCopy.string("profiles.versions")) {
                ForEach(model.versions, id: \.version) { version in
                    HStack {
                        Text(PickerCopy.string("profiles.version \(version.version)"))
                        Text(version.updatedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        Text(model.differences(from: version).map(Self.fieldName).joined(separator: ", ")).font(.caption)
                        Spacer()
                        Button(PickerCopy.string("profiles.revert")) { Task { await model.revert(to: version.version) } }
                    }
                }
            }
            if let problem = model.problem {
                Text(Self.describe(problem)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(PickerCopy.string("profiles.save")) { Task { await model.save(); readiness = await model.readiness() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.hasChanges)
            }
        }
        .formStyle(.grouped)
        .task(id: model.draft) {
            await model.updateMarks()
            readiness = await model.readiness()
        }
    }

    /// "Gemini 3.8 Flash", or "Global model" when the profile follows it.
    private var pinnedModelName: String {
        guard let pinned = model.draft?.model else { return PickerCopy.string("profiles.model.global") }
        let row = providers.rows.first { $0.id == pinned.provider }
        let name = row?.models.first { $0.id == pinned.model }?.displayName ?? pinned.model.rawValue
        return row.map { "\(name) · \($0.name)" } ?? name
    }

    private func binding<Value>(_ path: WritableKeyPath<Profile, Value>) -> Binding<Value> {
        Binding(get: { model.draft![keyPath: path] }, set: { model.draft?[keyPath: path] = $0 })
    }

    // MARK: Files

    private func export(includeSamples: Bool) {
        guard let data = try? model.export(includeSamples: includeSamples) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ProfileStore.exportExtension) ?? .json]
        panel.nameFieldStringValue = (model.draft?.name ?? "profile") + "." + ProfileStore.exportExtension
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url, options: .atomic) }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ProfileStore.exportExtension) ?? .json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        Task { try? await model.importProfile(data) }
    }

    // MARK: Copy

    static func name(_ value: ProfileSettings.Register) -> String { Presentation.Entry(key: "profiles.register." + value.rawValue).text }
    static func name(_ value: ProfileSettings.Tone) -> String { Presentation.Entry(key: "profiles.tone." + value.rawValue).text }
    static func name(_ value: ProfileSettings.Length) -> String { Presentation.Entry(key: "profiles.length." + value.rawValue).text }
    static func name(_ value: ProfileSettings.Preserved) -> String { Presentation.Entry(key: "profiles.preserve." + value.rawValue).text }
    static func fieldName(_ field: String) -> String { Presentation.Entry(key: "profiles.field." + field).text }

    static func describe(_ problem: ProfileError) -> String {
        switch problem {
        case .nameEmpty, .nameTooLong: PickerCopy.string("profiles.problem.name")
        case .guidanceTooLong: PickerCopy.string("profiles.problem.guidance")
        case .tooManyExamples, .duplicateExample: PickerCopy.string("profiles.problem.examples")
        case .exampleEmpty, .exampleTooLong: PickerCopy.string("profiles.problem.example")
        case .tooManySamples, .sampleEmpty, .sampleTooLong: PickerCopy.string("profiles.problem.sample")
        case .symbolEmpty, .temperatureOutOfRange, .invalidVersion, .spellingOnlyChangesRegister, .spellingOnlyTranslates,
             .invalidTargetLanguage, .invalidLengthBand: PickerCopy.string("profiles.problem.settings")
        }
    }
}

private struct ExampleRow: View {
    let model: ProfilesPaneModel
    let example: Example

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(example.input).foregroundStyle(.secondary)
            Text(example.output)
            HStack {
                if model.marks.notSentForBudget.contains(example.id) {
                    Text(PickerCopy.string("profiles.example.notSentBudget")).font(.caption).foregroundStyle(.secondary)
                }
                if !model.findings(example).isEmpty {
                    Text(PickerCopy.string("profiles.example.personalData")).font(.caption).foregroundStyle(.orange)
                    Button(PickerCopy.string("picker.correct.useStandIns")) { Task { await model.standIns(for: example) } }
                        .controlSize(.small)
                }
                Spacer()
                Button(role: .destructive) { Task { await model.deleteExample(example.id) } } label: {
                    Image(systemName: "trash").frame(width: 22, height: 22).contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel(PickerCopy.string("profiles.example.delete"))
            }
        }
    }
}

private struct AddExampleRow: View {
    let model: ProfilesPaneModel
    @State private var input = ""
    @State private var output = ""

    var body: some View {
        VStack(alignment: .leading) {
            TextField(PickerCopy.string("profiles.example.input"), text: $input)
            TextField(PickerCopy.string("profiles.example.output"), text: $output)
            Button(PickerCopy.string("profiles.example.add")) {
                let (newInput, newOutput) = (input, output)
                input = ""
                output = ""
                Task { await model.addExample(input: newInput, output: newOutput) }
            }
            .disabled(input.isEmpty || output.isEmpty)
        }
    }
}

private struct SampleRow: View {
    let model: ProfilesPaneModel
    let sample: Sample

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(sample.text)
                Spacer()
                Button(role: .destructive) { model.removeSample(sample.id) } label: {
                    Image(systemName: "trash").frame(width: 22, height: 22).contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel(PickerCopy.string("profiles.sample.delete"))
            }
            if let result = model.tryItResults[sample.id] {
                if result.noChanges {
                    Text(PickerCopy.string("picker.noChanges")).font(.callout).foregroundStyle(.secondary)
                } else if let text = result.text {
                    Text(text).font(.callout)
                }
                ForEach(Array(result.flags.enumerated()), id: \.offset) { _, flag in
                    Label(PickerCopy.flag(flag), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if let ratio = result.lengthRatio {
                    Text(PickerCopy.string("profiles.tryIt.length \(ratio.formatted(.number.precision(.fractionLength(2))))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let failure = result.failure, case .failed(let reason, _) = failure {
                    Text(Presentation.failure(reason).text).font(.caption).foregroundStyle(.red)
                }
            }
            if let previous = sample.previousResult {
                Text(PickerCopy.string("profiles.tryIt.previous \(previous.profileVersion) \(previous.text)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AddSampleRow: View {
    let model: ProfilesPaneModel
    @State private var text = ""

    var body: some View {
        HStack {
            TextField(PickerCopy.string("profiles.sample.new"), text: $text)
            Button(PickerCopy.string("profiles.sample.add")) {
                model.addSample(text)
                text = ""
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

/// The profile's symbol, chosen from a grid instead of typed by its system name.
private struct SymbolGrid: View {
    let selected: String?
    let choose: (String) -> Void

    static let symbols = [
        "textformat.abc", "briefcase", "building.columns", "face.smiling", "pencil", "envelope",
        "bubble.left.and.bubble.right", "doc.text", "graduationcap", "heart", "star", "megaphone",
        "newspaper", "book", "globe", "person.2", "hand.wave", "sparkles",
        "scissors", "list.bullet", "checkmark.seal", "lightbulb", "quote.bubble", "theatermasks",
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 6), spacing: 6) {
            ForEach(Self.symbols, id: \.self) { symbol in
                Button { choose(symbol) } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 15))
                        .frame(width: 34, height: 30)
                        .background(symbol == selected ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.clear),
                                    in: .rect(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbol)
            }
        }
        .padding(12)
    }
}
