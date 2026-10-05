import Foundation

/// A forward migration of one file kind, from `fromVersion` to `fromVersion + 1`
/// (ARCHITECTURE §4.2). It edits the decoded JSON object, so it runs before any type
/// sees the file — the shape the type expects today may not exist in the old file.
public struct StoreMigration: Sendable {
    public let fromVersion: Int
    public let migrate: @Sendable (inout [String: Any]) throws -> Void

    public init(from version: Int, _ migrate: @escaping @Sendable (inout [String: Any]) throws -> Void) {
        self.fromVersion = version
        self.migrate = migrate
    }

    /// Version 0 is a file written before `schemaVersion` existed: it gains the key and
    /// nothing else. Every file kind starts its chain with it, so the scaffold is in
    /// place before the first real change of shape.
    public static let stampVersion = StoreMigration(from: 0) { _ in }
}

/// What reading a file found.
public enum StoreRead<Value> {
    /// The file does not exist.
    case missing
    case loaded(Value, migratedFrom: Int?)
    /// The file could not be read; it was moved aside to `quarantinedAt`.
    case quarantined(URL)
}

public enum StoreError: Error, Equatable, Sendable {
    /// The file was written by a newer Quill: it is left untouched.
    case newerSchema(found: Int, supported: Int)
    case writeFailed(String)
}

/// Reads and writes the store's JSON files: atomic writes, `schemaVersion`, forward
/// migrations and corrupt-file quarantine (ARCHITECTURE §4.2).
public struct StoreFiles: Sendable {
    /// How long a quarantined file is kept.
    public static let quarantineLifetime: TimeInterval = 30 * 24 * 60 * 60
    static let quarantineMarker = ".corrupt-"

    public let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// `value` as a file's bytes: its own keys plus `schemaVersion`, sorted and pretty.
    public func encode<T: Encodable>(_ value: T, schemaVersion: Int) throws -> Data {
        let payload = try RewriteKitCoding.encoder().encode(value)
        guard var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw StoreError.writeFailed("\(T.self) does not encode as an object")
        }
        object["schemaVersion"] = schemaVersion
        return try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Writes `value`: a temporary file in the same directory, then a rename, so a crash
    /// leaves the old file or the new one, never half of either.
    public func write<T: Encodable>(_ value: T, schemaVersion: Int, to url: URL) throws {
        let data = try encode(value, schemaVersion: schemaVersion)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw StoreError.writeFailed("\(error)")
        }
    }

    /// Why bytes could not become a value.
    public enum DecodeFailure: Error, Equatable, Sendable {
        /// Written by a newer Quill.
        case newerSchema(found: Int, supported: Int)
        /// Not JSON, not an object, a missing migration, one that threw, or a value that
        /// fails validation.
        case unreadable(String)
    }

    /// Decodes bytes, running `migrations` up to `schemaVersion`. Returns the version the
    /// bytes were at when a migration ran.
    public func decode<T: Decodable>(
        _ type: T.Type, from data: Data, schemaVersion: Int, migrations: [StoreMigration]
    ) throws(DecodeFailure) -> (value: T, migratedFrom: Int?) {
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DecodeFailure.unreadable("not a JSON object")
            }
            object = parsed
        } catch let failure as DecodeFailure {
            throw failure
        } catch {
            throw .unreadable("\(error)")
        }
        let found = object["schemaVersion"] as? Int ?? 0
        if found > schemaVersion { throw .newerSchema(found: found, supported: schemaVersion) }
        var migrated = object
        do {
            for version in found..<schemaVersion {
                guard let step = migrations.first(where: { $0.fromVersion == version }) else {
                    throw DecodeFailure.unreadable("no migration from version \(version)")
                }
                try step.migrate(&migrated)
                migrated["schemaVersion"] = version + 1
            }
            migrated.removeValue(forKey: "schemaVersion")
            let value = try RewriteKitCoding.decoder().decode(
                T.self, from: try JSONSerialization.data(withJSONObject: migrated))
            return (value, found == schemaVersion ? nil : found)
        } catch let failure as DecodeFailure {
            throw failure
        } catch {
            throw .unreadable("\(error)")
        }
    }

    /// Reads a file and rewrites it when a migration ran. An unreadable file is moved
    /// aside, never overwritten. A file from a newer schema is an error, not corruption:
    /// a downgrade must not destroy it.
    public func read<T: Codable>(
        _ type: T.Type, at url: URL, schemaVersion: Int, migrations: [StoreMigration]
    ) throws -> StoreRead<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .quarantined(try quarantine(url)) }
        let decoded: (value: T, migratedFrom: Int?)
        do throws(DecodeFailure) {
            decoded = try decode(T.self, from: data, schemaVersion: schemaVersion, migrations: migrations)
        } catch {
            switch error {
            case .newerSchema(let found, let supported):
                throw StoreError.newerSchema(found: found, supported: supported)
            case .unreadable:
                return .quarantined(try quarantine(url))
            }
        }
        if decoded.migratedFrom != nil { try write(decoded.value, schemaVersion: schemaVersion, to: url) }
        return .loaded(decoded.value, migratedFrom: decoded.migratedFrom)
    }

    /// Moves `url` aside as `<name>.corrupt-<date>.json` in the same directory. Never
    /// replaces an earlier quarantined file: a second one the same second gets a counter.
    @discardableResult
    public func quarantine(_ url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let stamp = now().formatted(Self.stampStyle)
        var candidate = directory.appendingPathComponent("\(base)\(Self.quarantineMarker)\(stamp).json")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)\(Self.quarantineMarker)\(stamp)-\(counter).json")
            counter += 1
        }
        try FileManager.default.moveItem(at: url, to: candidate)
        return candidate
    }

    /// Deletes quarantined files under `directory` older than 30 days, by the date in
    /// their name. Returns what it deleted.
    @discardableResult
    public func sweepQuarantine(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let cutoff = now().addingTimeInterval(-Self.quarantineLifetime)
        var deleted: [URL] = []
        for case let url as URL in enumerator {
            guard let date = Self.quarantineDate(of: url), date < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { deleted.append(url) }
        }
        return deleted
    }

    /// The date a quarantined file was set aside, read from its name.
    static func quarantineDate(of url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let marker = name.range(of: quarantineMarker, options: .backwards) else { return nil }
        let stamp = name[marker.upperBound...].prefix(stampLength)
        return try? stampStyle.parse(String(stamp))
    }

    static let stampLength = "20261003T235900Z".count

    /// `20261003T235900Z`: sortable, and free of characters a file name should not hold.
    static let stampStyle = Date.ISO8601FormatStyle(
        dateSeparator: .omitted, dateTimeSeparator: .standard, timeSeparator: .omitted, timeZone: .gmt)
}
