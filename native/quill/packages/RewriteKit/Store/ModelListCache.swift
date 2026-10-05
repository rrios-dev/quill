import Foundation
import ModelKit

/// `cache/models-<provider>.json` (ARCHITECTURE §4.2): model lists with prices,
/// refreshed on demand or once they are older than 24 hours. Listing a server's models
/// is a network call, so it happens only from the Providers pane or when a list is
/// stale — never behind the user's back on a rewrite.
public final class ModelListCache: @unchecked Sendable {
    public static let schemaVersion = 1
    public static let lifetime: TimeInterval = 24 * 60 * 60

    public struct Entry: Codable, Equatable, Sendable {
        public var fetchedAt: Date
        public var models: [CachedModel]
    }

    /// `ModelDescriptor` as stored.
    public struct CachedModel: Codable, Equatable, Sendable {
        public var id: String
        public var displayName: String
        public var contextTokens: Int?
        public var isRecommended: Bool
        public var inputPerMillion: Double?
        public var outputPerMillion: Double?
        public var vendor: String?

        public init(_ descriptor: ModelDescriptor) {
            id = descriptor.id.rawValue
            displayName = descriptor.displayName
            contextTokens = descriptor.contextTokens
            isRecommended = descriptor.isRecommended
            inputPerMillion = descriptor.pricing?.inputPerMillion
            outputPerMillion = descriptor.pricing?.outputPerMillion
            vendor = descriptor.vendor
        }

        public var descriptor: ModelDescriptor {
            let pricing = inputPerMillion.flatMap { input in
                outputPerMillion.map { ModelPricing(inputPerMillion: input, outputPerMillion: $0) }
            }
            return ModelDescriptor(id: ModelID(rawValue: id), displayName: displayName, contextTokens: contextTokens,
                                   isRecommended: isRecommended, pricing: pricing, vendor: vendor)
        }
    }

    let directory: URL
    let files: StoreFiles
    private let lock = NSLock()
    /// Decoded lists, keyed by the file's modification date: a list of a few hundred
    /// models is decoded once, not on every look-up (the Providers pane asks often),
    /// and a file changed underneath (a reset, another write) is read again.
    private var memo: [ProviderID: (modified: Date, entry: Entry)] = [:]

    public init(dataDirectory: URL, files: StoreFiles = StoreFiles()) {
        directory = dataDirectory.appendingPathComponent("cache", isDirectory: true)
        self.files = files
    }

    func url(_ provider: ProviderID) -> URL { directory.appendingPathComponent("models-\(provider.rawValue).json") }

    /// The stored list, fresh or not; nil when there is none.
    public func cached(_ provider: ProviderID) -> Entry? {
        lock.withLock {
            let file = url(provider)
            guard let modified = Self.modificationDate(file) else {
                memo[provider] = nil
                return nil
            }
            if let memoized = memo[provider], memoized.modified == modified { return memoized.entry }
            if case .loaded(let entry, _)? = try? files.read(
                Entry.self, at: file, schemaVersion: Self.schemaVersion, migrations: [.stampVersion]) {
                memo[provider] = (modified, entry)
                return entry
            }
            memo[provider] = nil
            return nil
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public func isStale(_ entry: Entry) -> Bool { files.now().timeIntervalSince(entry.fetchedAt) > Self.lifetime }

    /// The list: the cached one while fresh, else fetched from the provider and stored.
    /// `force` refreshes on demand. A failed fetch keeps the stale list and rethrows.
    public func models(of provider: any ModelProvider, force: Bool = false) async throws -> [ModelDescriptor] {
        if !force, let entry = cached(provider.id), !isStale(entry) { return entry.models.map(\.descriptor) }
        let fetched = try await provider.models()
        let entry = Entry(fetchedAt: files.now().roundedToMilliseconds, models: fetched.map(CachedModel.init))
        try lock.withLock {
            try files.write(entry, schemaVersion: Self.schemaVersion, to: url(provider.id))
            memo[provider.id] = nil
        }
        return fetched
    }

    /// Forgets a provider's list (a custom server removed).
    public func remove(_ provider: ProviderID) {
        lock.withLock {
            _ = try? FileManager.default.removeItem(at: url(provider))
            memo[provider] = nil
        }
    }
}
