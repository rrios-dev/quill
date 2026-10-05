import GlassUI
import ModelKit
import RewriteKit
import SwiftUI

/// Settings → Providers & models. Renders `ProvidersPaneModel`.
///
/// One decision at the top — the model rewrites use — and the providers below, each a
/// single line that opens into its details. A provider's catalogue (hundreds of models
/// on OpenRouter) lives in the model browser, a searchable lazy list, never inline.
struct ProvidersPane: View {
    let model: ProvidersPaneModel
    @State private var keys: [ProviderID: String] = [:]
    @State private var addingServer = false
    @State private var browsing: Browse?
    @State private var expanded: Set<ProviderID> = []

    #if DEBUG
    /// `QUILL_SNAPSHOT_PICKER`: opens the model browser, to photograph it.
    static let debugBrowse = Notification.Name("dev.rrios.quill.debug.browse")
    #endif

    struct Browse: Identifiable {
        var provider: ProviderID?
        var id: String { provider?.rawValue ?? "*" }
    }

    var body: some View {
        Form {
            Section {
                GlobalModelRow(model: model) { browsing = Browse(provider: nil) }
            } header: {
                Text(PickerCopy.string("providers.global.title"))
            } footer: {
                Text(PickerCopy.string("providers.global.footer")).font(.caption).foregroundStyle(.secondary)
            }
            Section(PickerCopy.string("providers.section")) {
                ForEach(model.rows) { row in
                    ProviderRow(
                        model: model, row: row,
                        expanded: Binding(get: { expanded.contains(row.id) },
                                          set: { if $0 { expanded.insert(row.id) } else { expanded.remove(row.id) } }),
                        key: Binding(get: { keys[row.id] ?? "" }, set: { keys[row.id] = $0 }),
                        browse: { browsing = Browse(provider: row.id) })
                }
            }
            Section {
                Button(PickerCopy.string("providers.addServer")) { addingServer = true }
            } footer: {
                Text(PickerCopy.string("providers.server.rule")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await model.refresh()
            // The provider in use opens with its details: that is where the user looks.
            if expanded.isEmpty, let provider = model.globalModel?.provider { expanded.insert(provider) }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: Self.debugBrowse)) { _ in browsing = Browse(provider: nil) }
        #endif
        .sheet(isPresented: $addingServer) { AddServerSheet(model: model, isPresented: $addingServer) }
        .sheet(item: $browsing) { browse in
            ModelBrowser(model: model, provider: browse.provider, current: model.globalModel) { selection in
                model.choose(selection)
            }
        }
        .alert(PickerCopy.string("providers.notice.title"), isPresented: Binding(
            get: { model.notice != nil }, set: { if !$0 { model.declineNotice() } })) {
            Button(PickerCopy.string("providers.notice.accept")) { model.acceptNotice() }
            Button(PickerCopy.string("picker.action.cancel"), role: .cancel) { model.declineNotice() }
        } message: {
            if let notice = model.notice {
                Text(Presentation.tradeoff(.textLeavesDevice(recipients: notice.recipients)).text)
            }
        }
    }
}

// MARK: - The model rewrites use

private struct GlobalModelRow: View {
    let model: ProvidersPaneModel
    let change: () -> Void

    var body: some View {
        HStack(spacing: Metrics.Spacing.regular) {
            if let chosen = model.globalDescriptor {
                ProviderIcon(row: chosen.row)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chosen.model.displayName).font(.body.weight(.medium))
                    HStack(spacing: Metrics.Spacing.snug) {
                        Text(chosen.row.name)
                        ModelFacts(model: chosen.model)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Metrics.Spacing.snug)
                ReadinessBadge(label: model.readiness(of: chosen.model, provider: chosen.row.id))
            } else {
                Image(systemName: "questionmark.circle").font(.title2).foregroundStyle(.secondary)
                    .frame(width: 28).accessibilityHidden(true)
                Text(PickerCopy.string("providers.global.none")).foregroundStyle(.secondary)
                Spacer()
            }
            Button(PickerCopy.string("providers.global.change"), action: change)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - A provider

private struct ProviderRow: View {
    let model: ProvidersPaneModel
    let row: ProvidersPaneModel.Row
    @Binding var expanded: Bool
    @Binding var key: String
    let browse: () -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: Metrics.Spacing.regular) {
                tradeoffs
                if row.needsKey { keyField }
                connection
                models
                if row.isCustom {
                    Button(PickerCopy.string("providers.server.remove"), role: .destructive) {
                        Task { await model.removeCustomServer(row.id) }
                    }
                }
            }
            .padding(.vertical, Metrics.Spacing.snug)
        } label: {
            HStack(spacing: Metrics.Spacing.regular) {
                ProviderIcon(row: row)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.body.weight(.medium))
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: Metrics.Spacing.snug)
                StatusBadge(status: status)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.ambarQuick) { expanded.toggle() } }
        }
    }

    private var summary: String {
        if row.isCustom, let address = row.address {
            return PickerCopy.string("providers.summary.custom \(address.host() ?? address.absoluteString)")
        }
        switch row.id.rawValue {
        case "apple.on-device": return PickerCopy.string("providers.summary.onDevice")
        case "openrouter": return PickerCopy.string("providers.summary.openrouter")
        case "vercel-ai-gateway": return PickerCopy.string("providers.summary.vercel")
        case "openai": return PickerCopy.string("providers.summary.openai")
        default: return ""
        }
    }

    private var status: StatusBadge.Status {
        if case .unavailable? = row.availability, let entry = model.status(of: row) { return .problem(entry.text) }
        if row.needsKey, !row.hasKey { return .idle(PickerCopy.string("providers.status.noKey")) }
        switch row.connection {
        case .ok?: return .ready(PickerCopy.string("providers.status.connected"))
        case .failed(let code)?: return .problem(Presentation.providerError(code).text)
        case nil: return row.needsKey ? .ready(PickerCopy.string("providers.status.keySaved"))
                                      : .ready(PickerCopy.string("providers.status.ready"))
        }
    }

    private var tradeoffs: some View {
        Grid(alignment: .leading, horizontalSpacing: Metrics.Spacing.section, verticalSpacing: Metrics.Spacing.tight) {
            GridRow(alignment: .top) {
                TradeoffColumn(items: row.advantages, symbol: "checkmark", tint: .green)
                TradeoffColumn(items: row.drawbacks, symbol: "minus", tint: .secondary)
            }
        }
    }

    private var keyField: some View {
        HStack {
            SecureField(PickerCopy.string(row.hasKey ? "providers.key.replace" : "providers.key.enter"), text: $key)
                .textFieldStyle(.roundedBorder)
            Button(PickerCopy.string("providers.key.save")) {
                let entered = key
                key = ""
                Task { try? await model.setKey(entered, for: row.id) }
            }
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if row.hasKey {
                Button(PickerCopy.string("providers.key.remove"), role: .destructive) {
                    Task { try? await model.removeKey(for: row.id) }
                }
            }
        }
    }

    @ViewBuilder private var connection: some View {
        if !row.needsKey || row.hasKey {
            HStack(spacing: Metrics.Spacing.snug) {
                Button(PickerCopy.string("providers.test")) { Task { await model.testConnection(row.id) } }
                if case .ok(let count)? = row.connection {
                    Text(PickerCopy.string("providers.test.ok \(count)")).font(.callout).foregroundStyle(.secondary)
                }
                if let failure = row.modelsFailure, row.connection == nil {
                    Text(Presentation.providerError(failure).text).font(.callout).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder private var models: some View {
        let featured = model.featuredModels(of: row)
        if !featured.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(featured) { descriptor in
                    ModelRow(model: model, provider: row.id, descriptor: descriptor)
                }
            }
            if row.models.count > featured.count {
                Button(action: browse) {
                    HStack(spacing: Metrics.Spacing.tight) {
                        Text(PickerCopy.string("providers.models.browse"))
                        Text(row.models.count.formatted()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct TradeoffColumn: View {
    let items: [Tradeoff]
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.tight) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, tradeoff in
                Label {
                    Text(Presentation.tradeoff(tradeoff).text).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tint).font(.caption.weight(.bold))
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A model to choose, with what helps to choose it: readiness, price and context.
private struct ModelRow: View {
    let model: ProvidersPaneModel
    let provider: ProviderID
    let descriptor: ModelDescriptor
    /// The selection this list chooses for: the global model, or a profile's.
    var current: ModelSelection?
    var onChoose: ((ModelSelection) -> Void)?

    var body: some View {
        let selection = ModelSelection(provider: provider, model: descriptor.id)
        let chosen = (onChoose == nil ? model.globalModel : current) == selection
        Button { (onChoose ?? model.choose)(selection) } label: {
            HStack(spacing: Metrics.Spacing.snug) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .font(.body)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Metrics.Spacing.tight) {
                        Text(descriptor.displayName).lineLimit(1)
                        if descriptor.isRecommended {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                                .accessibilityLabel(PickerCopy.string("providers.recommended"))
                        }
                    }
                    ModelFacts(model: descriptor).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: Metrics.Spacing.snug)
                ReadinessBadge(label: model.readiness(of: descriptor, provider: provider))
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}

/// Price and context, the two numbers that decide between models.
private struct ModelFacts: View {
    let model: ModelDescriptor

    var body: some View {
        HStack(spacing: Metrics.Spacing.snug) {
            if let pricing = model.pricing {
                Text(PickerCopy.string("providers.price \(PickerCopy.cost(pricing.inputPerMillion)) \(PickerCopy.cost(pricing.outputPerMillion))"))
            }
            if let context = model.contextTokens {
                Text(PickerCopy.string("providers.context \(context.formatted(.number.notation(.compactName)))"))
            }
        }
        .lineLimit(1)
    }
}

// MARK: - Badges and icons

/// Where the text goes, as a glyph: this Mac, a hosted service, your own server.
private struct ProviderIcon: View {
    let row: ProvidersPaneModel.Row

    var body: some View {
        Image(systemName: row.isCustom ? "server.rack" : (row.isRemote ? "cloud" : "laptopcomputer"))
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(row.isRemote || row.isCustom ? AnyShapeStyle(Color.blue.gradient) : AnyShapeStyle(Color.gray.gradient),
                        in: .rect(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}

struct ReadinessBadge: View {
    let label: ReadinessLabel

    var body: some View {
        Text(ReadinessCopy.label(label))
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
            .fixedSize()
    }

    private var tint: Color {
        switch label {
        case .worksWell: .green
        case .mayNeedReview: .yellow
        case .notRecommended: .orange
        case .notEvaluated, .notEvaluatedEdited: .secondary
        }
    }
}

private struct StatusBadge: View {
    enum Status {
        case ready(String)
        case idle(String)
        case problem(String)
    }

    let status: Status

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help(text)
    }

    private var text: String {
        switch status {
        case .ready(let text), .idle(let text), .problem(let text): text
        }
    }

    private var tint: Color {
        switch status {
        case .ready: .green
        case .idle: .gray
        case .problem: .orange
        }
    }
}

// MARK: - The model browser

/// Every model of every provider (or one), searchable. A lazy list: a catalogue of
/// hundreds scrolls as smoothly as one of ten.
struct ModelBrowser: View {
    let model: ProvidersPaneModel
    let provider: ProviderID?
    let current: ModelSelection?
    let onChoose: (ModelSelection) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.Spacing.snug) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(PickerCopy.string("providers.browser.search"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .accessibilityLabel(PickerCopy.string("providers.browser.search"))
            }
            .padding(Metrics.Spacing.regular)
            Divider()
            let groups = model.browse(query, provider: provider)
            if groups.isEmpty {
                Text(PickerCopy.string("providers.browser.empty")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.row.id) { group in
                        Section(group.row.name) {
                            ForEach(group.models) { descriptor in
                                ModelRow(model: model, provider: group.row.id, descriptor: descriptor, current: current) { selection in
                                    onChoose(selection)
                                    dismiss()
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Spacer()
                Button(PickerCopy.string("picker.action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(Metrics.Spacing.regular)
        }
        .frame(width: 560, height: 520)
    }
}

// MARK: - A custom server

private struct AddServerSheet: View {
    let model: ProvidersPaneModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var address = "http://localhost:11434/v1"
    @State private var requiresKey = false
    @State private var key = ""
    @State private var problem: String?

    var body: some View {
        Form {
            TextField(PickerCopy.string("providers.server.name"), text: $name)
            TextField(PickerCopy.string("providers.server.address"), text: $address)
            Toggle(PickerCopy.string("providers.server.requiresKey"), isOn: $requiresKey)
            if requiresKey { SecureField(PickerCopy.string("providers.key.enter"), text: $key) }
            Text(PickerCopy.string("providers.server.rule")).font(.caption).foregroundStyle(.secondary)
            if let problem { Text(problem).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(PickerCopy.string("picker.action.cancel")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(PickerCopy.string("providers.server.add")) {
                    Task {
                        do {
                            try await model.addCustomServer(name: name, address: address, requiresKey: requiresKey, key: key)
                            isPresented = false
                        } catch let error as ProvidersPaneModel.AddServerError {
                            problem = Self.describe(error)
                        } catch {
                            problem = PickerCopy.string("providers.server.saveProblem")
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    static func describe(_ error: ProvidersPaneModel.AddServerError) -> String {
        switch error {
        case .name: PickerCopy.string("providers.server.nameProblem")
        case .address(let problem): ProvidersPaneModel.explanation(problem).text
        case .key: PickerCopy.string("providers.server.keyProblem")
        case .saving: PickerCopy.string("providers.server.saveProblem")
        }
    }
}

/// The readiness labels' copy (ARCHITECTURE §5.1).
enum ReadinessCopy {
    static func label(_ label: ReadinessLabel) -> String {
        switch label {
        case .worksWell: PickerCopy.string("readiness.worksWell")
        case .mayNeedReview: PickerCopy.string("readiness.mayNeedReview")
        case .notRecommended: PickerCopy.string("readiness.notRecommended")
        case .notEvaluated: PickerCopy.string("readiness.notEvaluated")
        case .notEvaluatedEdited: PickerCopy.string("readiness.notEvaluatedEdited")
        }
    }
}
