import Foundation
import ModelKit
import Observation
import QuillSupport
import RewriteKit

/// Settings → Providers & models (PRODUCT F4 step 5, PROVIDERS §3–4): each provider with
/// its advantages and drawbacks, its key, its models with prices and readiness, a
/// connection test, and the custom servers. The view only renders this.
@MainActor
@Observable
final class ProvidersPaneModel {
    struct Row: Identifiable, Equatable {
        var id: ProviderID
        var name: String
        var isCustom: Bool
        var isRemote: Bool
        var recipients: [Recipient]
        var advantages: [Tradeoff]
        var drawbacks: [Tradeoff]
        var needsKey: Bool
        var hasKey: Bool
        var availability: ProviderAvailability?
        var models: [ModelDescriptor] = []
        var modelsFailure: ProviderError.Code?
        var connection: Connection?
        var address: URL?
    }

    enum Connection: Equatable {
        case ok(models: Int)
        case failed(ProviderError.Code)
    }

    /// The once-per-provider notice before a hosted provider becomes the global choice.
    struct Notice: Equatable {
        var selection: ModelSelection
        var providerName: String
        var recipients: [Recipient]
    }

    enum AddServerError: Error, Equatable {
        case name
        case address(ServerAddress.Problem)
        case key
        case saving(String)
    }

    private(set) var rows: [Row] = []
    private(set) var globalModel: ModelSelection?
    private(set) var notice: Notice?
    /// Every listed model's readiness label for the last used profile, computed when the
    /// lists change — never while drawing a row (a list holds hundreds).
    private(set) var labels: [ModelSelection: ReadinessLabel] = [:]

    private let settings: SettingsStore
    private let profiles: ProfileStore
    private let registry: ProviderRegistryHolder
    private let credentials: any CredentialStore
    private let cache: ModelListCache
    private let readinessIndex: ReadinessIndex
    private let composer: PromptComposer?
    private let log = QuillLog(category: "providers")

    init(settings: SettingsStore, profiles: ProfileStore, registry: ProviderRegistryHolder,
         credentials: any CredentialStore, cache: ModelListCache, readiness: ReadinessIndex,
         composer: PromptComposer? = try? PromptComposer()) {
        self.settings = settings
        self.profiles = profiles
        self.registry = registry
        self.credentials = credentials
        self.cache = cache
        self.readinessIndex = readiness
        self.composer = composer
    }

    // MARK: Rows

    /// Re-reads every provider: availability (cheap, no network), the key, the cached
    /// model list. Called when the pane appears and after every change.
    func refresh() async {
        let current = (try? settings.settings()) ?? QuillSettings()
        globalModel = current.globalModel
        let servers = Dictionary(uniqueKeysWithValues: current.customServers.map { ($0.id, $0) })
        var rows: [Row] = []
        for provider in registry.current.providers {
            let descriptor = provider.descriptor
            let recipients: [Recipient]
            let remote: Bool
            switch descriptor.traits.execution {
            case .onDevice: (recipients, remote) = ([], false)
            case .remote(let list): (recipients, remote) = (list, true)
            }
            let needsKey = descriptor.traits.credential == .apiKey
            let hasKey = needsKey && ((try? credentials.secret(for: descriptor.id)) ?? nil)?.isEmpty == false
            let previous = self.rows.first { $0.id == descriptor.id }
            rows.append(Row(
                id: descriptor.id, name: descriptor.displayName, isCustom: servers[descriptor.id] != nil,
                isRemote: remote, recipients: recipients, advantages: descriptor.advantages,
                drawbacks: descriptor.drawbacks, needsKey: needsKey, hasKey: hasKey,
                availability: await provider.availability(),
                models: cache.cached(descriptor.id)?.models.map(\.descriptor) ?? previous?.models ?? [],
                modelsFailure: previous?.modelsFailure, connection: previous?.connection,
                address: servers[descriptor.id]?.baseURL))
        }
        self.rows = rows
        // The on-device model lists itself without the network; a server's list is
        // fetched only on request (ARCHITECTURE §6).
        for row in rows where !row.isRemote && !row.isCustom && row.models.isEmpty {
            await loadModels(for: row.id)
        }
        recomputeLabels()
    }

    /// One batch per refresh: the profile is read once and the prompt hashes are
    /// computed once per strategy (`ReadinessIndex.labels`).
    private func recomputeLabels() {
        guard let composer, let profile = lastUsedProfile() else {
            labels = [:]
            return
        }
        let models = rows.flatMap { row in
            row.models.map { (selection: ModelSelection(provider: row.id, model: $0.id), contextTokens: context(of: $0, provider: row.id)) }
        }
        labels = readinessIndex.labels(for: profile, models: models, composer: composer)
    }

    private func lastUsedProfile() -> Profile? {
        let current = (try? settings.settings()) ?? QuillSettings()
        let all = (try? profiles.all().profiles) ?? []
        return all.first(where: { $0.id == current.lastUsedProfile }) ?? all.first
    }

    private func context(of model: ModelDescriptor, provider id: ProviderID) -> Int? {
        model.contextTokens ?? registry.current[id]?.descriptor.traits.maxContextTokens
    }

    // MARK: What the pane lists

    /// The few models a provider shows inline: the chosen one, then the recommended
    /// (README Q6); the rest are one search away in the model browser.
    func featuredModels(of row: Row) -> [ModelDescriptor] {
        if row.models.count <= Self.inlineLimit { return row.models }
        var featured = row.models.filter { $0.isRecommended }
        if let globalModel, globalModel.provider == row.id, !featured.contains(where: { $0.id == globalModel.model }),
           let chosen = row.models.first(where: { $0.id == globalModel.model }) {
            featured.insert(chosen, at: 0)
        }
        return Array(featured.prefix(Self.inlineLimit))
    }

    static let inlineLimit = 6

    /// The chosen global model's descriptor, from the cached lists.
    var globalDescriptor: (row: Row, model: ModelDescriptor)? {
        guard let globalModel, let row = rows.first(where: { $0.id == globalModel.provider }),
              let descriptor = row.models.first(where: { $0.id == globalModel.model }) else { return nil }
        return (row, descriptor)
    }

    /// The browser's list: providers with models, filtered by `query` on the name and
    /// the id, recommended first and then by name.
    func browse(_ query: String, provider: ProviderID? = nil) -> [(row: Row, models: [ModelDescriptor])] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        return rows.compactMap { row in
            guard provider == nil || row.id == provider else { return nil }
            let matching = row.models.filter { model in
                let haystack = (model.displayName + " " + model.id.rawValue).lowercased()
                return terms.allSatisfy { haystack.contains($0) }
            }
            .sorted { lhs, rhs in
                lhs.isRecommended != rhs.isRecommended
                    ? lhs.isRecommended
                    : lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
            return matching.isEmpty ? nil : (row, matching)
        }
    }

    /// "Needs a key", with its action, for a provider whose key is missing.
    func status(of row: Row) -> Presentation.Entry? {
        if case .unavailable(let reason)? = row.availability { return Presentation.unavailable(reason) }
        return nil
    }

    // MARK: Keys

    /// Stores a key the user typed or pasted. Keys never touch a file or a log.
    func setKey(_ key: String, for id: ProviderID) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try credentials.setSecret(trimmed, for: id)
        await refresh()
        // A new key is checked at once, and its models listed: the user did it to use them.
        await testConnection(id)
    }

    /// Deletes the provider's Keychain item.
    func removeKey(for id: ProviderID) async throws {
        try credentials.removeSecret(for: id)
        await refresh()
    }

    // MARK: Models

    /// The provider's models: the cache while fresh, the provider on `force` or when stale.
    func loadModels(for id: ProviderID, force: Bool = false) async {
        guard let provider = registry.current[id], let index = rows.firstIndex(where: { $0.id == id }) else { return }
        do {
            let models = try await cache.models(of: provider, force: force)
            rows[index].models = models
            rows[index].modelsFailure = nil
        } catch {
            rows[index].modelsFailure = ProviderError.normalize(error, provider: id).code
        }
        recomputeLabels()
    }

    /// "Test connection": lists the models, which needs the key and the network to work.
    func testConnection(_ id: ProviderID) async {
        await loadModels(for: id, force: true)
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].connection = rows[index].modelsFailure.map(Connection.failed) ?? .ok(models: rows[index].models.count)
    }

    /// The readiness label of the last used profile on a model (ARCHITECTURE §5.1): the
    /// batch's, or computed for this one model when it is not listed yet.
    func readiness(of model: ModelDescriptor, provider id: ProviderID) -> ReadinessLabel {
        let selection = ModelSelection(provider: id, model: model.id)
        if let label = labels[selection] { return label }
        guard let composer, let profile = lastUsedProfile() else { return .notEvaluated }
        return readinessIndex.label(for: profile, model: selection, contextTokens: context(of: model, provider: id), composer: composer)
    }

    // MARK: The global model

    /// Makes `selection` the global choice; a hosted provider the user has not been told
    /// about yet shows its notice first (once per provider).
    func choose(_ selection: ModelSelection) {
        guard let row = rows.first(where: { $0.id == selection.provider }) else { return }
        let notified = ((try? settings.settings()) ?? QuillSettings()).notifiedProviders.contains(row.id)
        if row.isRemote, !notified {
            notice = Notice(selection: selection, providerName: row.name, recipients: row.recipients)
            return
        }
        setGlobal(selection)
    }

    func acceptNotice() {
        guard let notice else { return }
        self.notice = nil
        do {
            try settings.update { $0.notifiedProviders.insert(notice.selection.provider) }
        } catch {
            log.error("could not record the notice: \(error)")
            return
        }
        setGlobal(notice.selection)
    }

    func declineNotice() { notice = nil }

    private func setGlobal(_ selection: ModelSelection) {
        do {
            try settings.update { $0.globalModel = selection }
            globalModel = selection
        } catch {
            log.error("could not save the model: \(error)")
        }
    }

    // MARK: Custom servers

    /// Adds an OpenAI-compatible server under PROVIDERS §4's address rule.
    @discardableResult
    func addCustomServer(name: String, address: String, requiresKey: Bool, key: String) async throws(AddServerError) -> ProviderID {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= ProfileLimits.nameCharacters else { throw .name }
        let url: URL
        switch ServerAddress.check(address) {
        case .success(let checked): url = checked.url
        case .failure(let problem): throw .address(problem)
        }
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresKey, trimmedKey.isEmpty { throw .key }
        let server = CustomServer(name: trimmedName, baseURL: url, requiresAPIKey: requiresKey)
        do {
            if requiresKey { try credentials.setSecret(trimmedKey, for: server.id) }
            try settings.update { $0.customServers.append(server) }
        } catch {
            try? credentials.removeSecret(for: server.id)
            throw .saving("\(error)")
        }
        await refresh()
        return server.id
    }

    /// Removes a server with its key and its cached model list. A global model on it is
    /// cleared rather than substituted (README D-16).
    func removeCustomServer(_ id: ProviderID) async {
        do {
            try settings.update { settings in
                settings.customServers.removeAll { $0.id == id }
                if settings.globalModel?.provider == id { settings.globalModel = nil }
            }
        } catch {
            log.error("could not remove the server: \(error)")
            return
        }
        try? credentials.removeSecret(for: id)
        cache.remove(id)
        await refresh()
    }

    /// Copy for an address the form refused.
    static func explanation(_ problem: ServerAddress.Problem) -> Presentation.Entry {
        switch problem {
        case .notAURL: Presentation.Entry(key: "providers.address.notAURL")
        case .unsupportedScheme: Presentation.Entry(key: "providers.address.scheme")
        case .plainHTTPToAddress(let host): Presentation.Entry(key: "providers.address.httpToAddress %@", arguments: [host])
        case .plainHTTPToRemoteName(let host): Presentation.Entry(key: "providers.address.httpToName %@", arguments: [host])
        }
    }
}
