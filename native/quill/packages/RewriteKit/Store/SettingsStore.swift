import Foundation
import ModelKit

/// `settings.json` (ARCHITECTURE §4.2). Thread-safe; every change is written at once.
public final class SettingsStore: @unchecked Sendable {
    public let url: URL
    let files: StoreFiles
    let migrations: [StoreMigration]

    private let lock = NSLock()
    private var cached: QuillSettings?
    private var observers: [UUID: @Sendable (QuillSettings, QuillSettings) -> Void] = [:]

    /// The migrations every `settings.json` runs through on load.
    public static let migrations: [StoreMigration] = [.stampVersion]

    private var loadReport: LoadReport = .notLoaded

    /// What the last load found, for the UI to report (a quarantined file is never silent).
    public var lastLoad: LoadReport { lock.withLock { loadReport } }

    public enum LoadReport: Equatable, Sendable {
        case notLoaded
        case created
        case loaded
        case migrated(from: Int)
        case quarantined(URL)
    }

    public init(dataDirectory: URL, files: StoreFiles = StoreFiles(),
                migrations: [StoreMigration] = SettingsStore.migrations) {
        self.url = dataDirectory.appendingPathComponent("settings.json")
        self.files = files
        self.migrations = migrations
    }

    /// The settings, read once and then kept; defaults when the file is missing or was
    /// quarantined.
    public func settings() throws -> QuillSettings {
        try lock.withLock { try loadLocked() }
    }

    /// Applies `change` and writes the result; observers hear about it after the write.
    @discardableResult
    public func update(_ change: (inout QuillSettings) throws -> Void) throws -> QuillSettings {
        let (old, new, listeners) = try lock.withLock { () throws -> (QuillSettings, QuillSettings, [@Sendable (QuillSettings, QuillSettings) -> Void]) in
            let old = try loadLocked()
            var new = old
            try change(&new)
            try new.validate()
            if new != old { try files.write(new, schemaVersion: QuillSettings.schemaVersion, to: url) }
            cached = new
            return (old, new, Array(observers.values))
        }
        if new != old { listeners.forEach { $0(old, new) } }
        return new
    }

    /// Called with (old, new) after every change that was written.
    @discardableResult
    public func observe(_ observer: @escaping @Sendable (QuillSettings, QuillSettings) -> Void) -> UUID {
        let token = UUID()
        lock.withLock { observers[token] = observer }
        return token
    }

    public func removeObserver(_ token: UUID) {
        lock.withLock { observers[token] = nil }
    }

    /// Forgets the cached value, so the next read goes back to the file ("Reset Quill").
    public func invalidate() {
        lock.withLock { cached = nil; loadReport = .notLoaded }
    }

    private func loadLocked() throws -> QuillSettings {
        if let cached { return cached }
        let value: QuillSettings
        switch try files.read(QuillSettings.self, at: url, schemaVersion: QuillSettings.schemaVersion,
                              migrations: migrations) {
        case .missing:
            value = QuillSettings()
            loadReport = .created
        case .loaded(let loaded, let from):
            value = loaded
            loadReport = from.map { .migrated(from: $0) } ?? .loaded
        case .quarantined(let moved):
            value = QuillSettings()
            loadReport = .quarantined(moved)
        }
        cached = value
        return value
    }
}

/// The registry the app uses, rebuilt from the shipped providers plus the custom servers
/// whenever the list changes (PROVIDERS §8 item 9). `ProviderRegistry` stays immutable;
/// this swaps in a new one, so a rewrite in flight keeps the registry it started with.
public final class ProviderRegistryHolder: @unchecked Sendable {
    public typealias CustomProviderFactory = @Sendable (CustomServer) -> any ModelProvider

    private let shipped: [any ModelProvider]
    private let makeCustom: CustomProviderFactory
    private let lock = NSLock()
    private var registry: ProviderRegistry
    private var servers: [CustomServer]

    /// Throws when a custom server collides with a shipped id: validation should have
    /// prevented it, and silently dropping a server would hide it from the user.
    public init(shipped: [any ModelProvider], customServers: [CustomServer],
                makeCustom: @escaping CustomProviderFactory) throws {
        self.shipped = shipped
        self.makeCustom = makeCustom
        self.servers = customServers
        self.registry = try ProviderRegistry(shipped + customServers.map(makeCustom))
    }

    /// The registry to start a rewrite with.
    public var current: ProviderRegistry { lock.withLock { registry } }

    /// Rebuilds when `customServers` differs from the list the registry was built from.
    /// Returns whether it rebuilt.
    @discardableResult
    public func update(customServers: [CustomServer]) throws -> Bool {
        try lock.withLock {
            guard customServers != servers else { return false }
            registry = try ProviderRegistry(shipped + customServers.map(makeCustom))
            servers = customServers
            return true
        }
    }

    /// Keeps the registry in step with `store`. Returns the observer token.
    @discardableResult
    public func follow(_ store: SettingsStore, onError: @escaping @Sendable (any Error) -> Void = { _ in }) -> UUID {
        store.observe { [weak self] old, new in
            guard old.customServers != new.customServers else { return }
            do { try self?.update(customServers: new.customServers) } catch { onError(error) }
        }
    }
}
