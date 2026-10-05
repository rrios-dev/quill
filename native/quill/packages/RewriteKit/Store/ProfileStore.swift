import Foundation
import ModelKit

/// `profiles/<uuid>/`: the current profile, its last 20 versions and its Try it samples
/// (ARCHITECTURE §4.2–4.3). Thread-safe.
public final class ProfileStore: @unchecked Sendable {
    public static let schemaVersion = 1
    /// Previous versions kept for compare and revert.
    public static let keptVersions = 20
    /// The extension of an exported profile.
    public static let exportExtension = "quillprofile"

    /// The migrations each file kind runs through on load.
    public static let profileMigrations: [StoreMigration] = [.stampVersion]
    public static let sampleMigrations: [StoreMigration] = [.stampVersion]
    public static let exportMigrations: [StoreMigration] = [.stampVersion]

    public let root: URL
    let files: StoreFiles
    let profileMigrations: [StoreMigration]
    private let lock = NSLock()

    public init(dataDirectory: URL, files: StoreFiles = StoreFiles(),
                profileMigrations: [StoreMigration] = ProfileStore.profileMigrations) {
        self.root = dataDirectory.appendingPathComponent("profiles", isDirectory: true)
        self.files = files
        self.profileMigrations = profileMigrations
    }

    /// Every profile that could be read, plus the files that were quarantined while
    /// reading, for the UI to report.
    public struct Listing: Sendable {
        public var profiles: [Profile]
        public var quarantined: [URL]
    }

    // MARK: Profiles

    public func all() throws -> Listing {
        try lock.withLock {
            var listing = Listing(profiles: [], quarantined: [])
            let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for directory in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
                switch try readCurrent(id) {
                case .loaded(let profile, _): listing.profiles.append(profile)
                case .quarantined(let url): listing.quarantined.append(url)
                case .missing: break
                }
            }
            return listing
        }
    }

    public func profile(_ id: UUID) throws -> Profile? {
        try lock.withLock {
            if case .loaded(let profile, _) = try readCurrent(id) { return profile }
            return nil
        }
    }

    /// Saves an edit. A new profile starts at version 1; an edit of a stored one archives
    /// the stored version and takes the next number. Saving what is already stored
    /// creates no version. Returns the profile as stored.
    @discardableResult
    public func save(_ profile: Profile) throws -> Profile {
        try lock.withLock { try saveLocked(profile) }
    }

    /// The archived versions, oldest first. The current one is not among them.
    public func versions(of id: UUID) throws -> [Profile] {
        try lock.withLock { try versionsLocked(id).map(\.profile) }
    }

    /// Makes an archived version current again — as a new version, so the revert itself
    /// can be reverted.
    @discardableResult
    public func revert(_ id: UUID, to version: Int) throws -> Profile {
        try lock.withLock {
            guard let old = try versionsLocked(id).first(where: { $0.profile.version == version })?.profile
            else { throw ProfileStoreError.versionNotFound(id, version) }
            return try saveLocked(old)
        }
    }

    /// Deletes a profile with its versions and samples. The caller also forgets it in
    /// the settings (`QuillSettings.forgetProfile`).
    public func delete(_ id: UUID) throws {
        try lock.withLock {
            let directory = directory(id)
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Deletes an example from the profile and from every stored version (ARCHITECTURE
    /// §4.3): deleted user text must not survive in the history. Only a file already set
    /// aside as corrupt keeps it, because it cannot be parsed (PRODUCT §7).
    @discardableResult
    public func deleteExample(_ exampleID: UUID, from id: UUID) throws -> Profile {
        try lock.withLock {
            guard case .loaded(var profile, _) = try readCurrent(id) else { throw ProfileStoreError.notFound(id) }
            if profile.examples.contains(where: { $0.id == exampleID }) {
                profile.examples.removeAll { $0.id == exampleID }
                profile = try saveLocked(profile)
            }
            for (url, var version) in try versionsLocked(id) where version.examples.contains(where: { $0.id == exampleID }) {
                version.examples.removeAll { $0.id == exampleID }
                try files.write(version, schemaVersion: Self.schemaVersion, to: url)
            }
            return profile
        }
    }

    // MARK: Samples

    public func samples(of id: UUID) throws -> SampleSet {
        try lock.withLock {
            switch try files.read(SampleFile.self, at: samplesURL(id), schemaVersion: Self.schemaVersion,
                                  migrations: Self.sampleMigrations) {
            case .loaded(let file, _): return file.samples
            case .missing, .quarantined: return SampleSet()
            }
        }
    }

    public func saveSamples(_ samples: SampleSet, for id: UUID) throws {
        try samples.validate()
        try lock.withLock {
            try files.write(SampleFile(samples: samples), schemaVersion: Self.schemaVersion, to: samplesURL(id))
        }
    }

    // MARK: Export and import

    /// A `.quillprofile` file. The UI warns before writing it: it holds user text
    /// (PRODUCT F3).
    public func export(_ id: UUID, includeSamples: Bool) throws -> Data {
        guard let profile = try profile(id) else { throw ProfileStoreError.notFound(id) }
        let samples = includeSamples ? try samples(of: id) : nil
        return try files.encode(ProfileExport(profile: profile, samples: samples), schemaVersion: Self.schemaVersion)
    }

    /// Imports an exported profile as a **new** profile: a new id and version 1, so it
    /// never replaces the one it was exported from, nor that one's history.
    @discardableResult
    public func importProfile(_ data: Data) throws -> Profile {
        let decoded: ProfileExport
        do throws(StoreFiles.DecodeFailure) {
            decoded = try files.decode(ProfileExport.self, from: data, schemaVersion: Self.schemaVersion,
                                       migrations: Self.exportMigrations).value
        } catch {
            switch error {
            case .newerSchema(let found, let supported):
                throw ProfileStoreError.importFromNewerVersion(found: found, supported: supported)
            case .unreadable(let reason):
                throw ProfileStoreError.importUnreadable(reason)
            }
        }
        var profile = decoded.profile
        profile.id = UUID()
        profile.version = 1
        let saved = try lock.withLock { try saveLocked(profile, isNew: true) }
        if let samples = decoded.samples, !samples.samples.isEmpty { try saveSamples(samples, for: saved.id) }
        return saved
    }

    // MARK: Built-ins

    /// The four built-ins on first run; nothing when any profile exists.
    @discardableResult
    public func seedIfEmpty(language: String) throws -> [Profile] {
        guard try all().profiles.isEmpty else { return [] }
        return try BuiltInProfiles.all(language: language, now: files.now()).map { try save($0) }
    }

    /// Brings back any built-in the user deleted, leaving every other profile as it is
    /// (PRODUCT F3 item 6). Returns the restored ones.
    @discardableResult
    public func restoreBuiltIns(language: String) throws -> [Profile] {
        let present = Set(try all().profiles.compactMap(\.builtIn))
        return try BuiltInProfile.shipped.filter { !present.contains($0) }.map {
            try save(BuiltInProfiles.make($0, language: language, now: files.now()))
        }
    }

    // MARK: Internals

    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func currentURL(_ id: UUID) -> URL { directory(id).appendingPathComponent("current.json") }
    private func versionsDirectory(_ id: UUID) -> URL { directory(id).appendingPathComponent("versions", isDirectory: true) }
    private func samplesURL(_ id: UUID) -> URL { directory(id).appendingPathComponent("samples.json") }

    private func readCurrent(_ id: UUID) throws -> StoreRead<Profile> {
        try files.read(Profile.self, at: currentURL(id), schemaVersion: Self.schemaVersion, migrations: profileMigrations)
    }

    private func saveLocked(_ incoming: Profile, isNew: Bool = false) throws -> Profile {
        try incoming.validate()
        var profile = incoming
        let stored: Profile? = isNew ? nil : {
            if case .loaded(let profile, _)? = try? readCurrent(incoming.id) { return profile }
            return nil
        }()
        if let stored {
            guard !Self.sameContent(stored, profile) else { return stored }
            try files.write(stored, schemaVersion: Self.schemaVersion,
                            to: versionsDirectory(profile.id).appendingPathComponent("\(stored.version).json"))
            profile.version = stored.version + 1
        } else {
            profile.version = 1
        }
        profile.updatedAt = files.now().roundedToMilliseconds
        try files.write(profile, schemaVersion: Self.schemaVersion, to: currentURL(profile.id))
        try pruneVersions(profile.id)
        return profile
    }

    /// Equal apart from the bookkeeping a save changes.
    static func sameContent(_ lhs: Profile, _ rhs: Profile) -> Bool {
        var rhs = rhs
        rhs.version = lhs.version
        rhs.updatedAt = lhs.updatedAt
        return lhs == rhs
    }

    /// Archived versions with their files, oldest first; unreadable ones are quarantined.
    private func versionsLocked(_ id: UUID) throws -> [(url: URL, profile: Profile)] {
        try versionFiles(id).compactMap { url in
            if case .loaded(let profile, _) = try files.read(
                Profile.self, at: url, schemaVersion: Self.schemaVersion, migrations: profileMigrations) {
                return (url, profile)
            }
            return nil
        }
    }

    /// `versions/<n>.json`, sorted by n.
    private func versionFiles(_ id: UUID) throws -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: versionsDirectory(id), includingPropertiesForKeys: nil)) ?? []
        return entries
            .compactMap { url in Int(url.deletingPathExtension().lastPathComponent).map { (url, $0) } }
            .filter { $0.0.pathExtension == "json" }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private func pruneVersions(_ id: UUID) throws {
        let all = try versionFiles(id)
        for url in all.dropLast(Self.keptVersions) { try FileManager.default.removeItem(at: url) }
    }
}

/// `samples.json`: an object, so it can carry `schemaVersion`.
struct SampleFile: Codable {
    var samples: SampleSet
}

/// A `.quillprofile` file.
struct ProfileExport: Codable {
    var profile: Profile
    var samples: SampleSet?
}

public enum ProfileStoreError: Error, Equatable, Sendable {
    case notFound(UUID)
    case versionNotFound(UUID, Int)
    case importUnreadable(String)
    case importFromNewerVersion(found: Int, supported: Int)
}

/// "Reset Quill" (PRODUCT §7): every file in the data folder and every key of the app's
/// own Keychain service. The bench's keys live in another service and are left alone.
public enum QuillReset {
    public struct Failure: Error, Sendable {
        public var files: [String]
        public var keychain: String?
    }

    /// Tries both halves even when one fails, and reports what remained.
    public static func run(dataDirectory: URL, credentials: any CredentialStore) throws {
        var failure = Failure(files: [], keychain: nil)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dataDirectory, includingPropertiesForKeys: nil, options: [])) ?? []
        for url in entries {
            do { try FileManager.default.removeItem(at: url) } catch { failure.files.append(url.lastPathComponent) }
        }
        do { try credentials.removeAll() } catch { failure.keychain = "\(error)" }
        if !failure.files.isEmpty || failure.keychain != nil { throw failure }
    }
}
