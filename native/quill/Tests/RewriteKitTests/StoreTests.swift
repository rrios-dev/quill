import Foundation
import ModelKit
import Testing

@testable import RewriteKit

/// A temporary data folder, removed when the test ends.
private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Every regular file under the folder, relative to it.
    func files() -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        return enumerator.compactMap { item -> String? in
            guard let file = item as? URL,
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            return String(file.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.count + 1))
        }.sorted()
    }
}

/// A clock the test moves by hand.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(days: Double) { lock.withLock { current = current.addingTimeInterval(days * 86_400) } }
    var files: StoreFiles { StoreFiles(now: { [self] in now }) }
}

private func profile(_ name: String = "Work", examples: [Example] = []) -> Profile {
    Profile(name: name, symbol: "briefcase", settings: ProfileSettings(scope: .rewrite), examples: examples)
}

private func jsonObject(_ url: URL) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

@Suite("Settings store")
struct SettingsStoreTests {
    @Test("a missing file gives the defaults and writes nothing until a change")
    func missingFile() throws {
        let folder = try TemporaryDirectory()
        let store = SettingsStore(dataDirectory: folder.url)
        #expect(try store.settings() == QuillSettings())
        #expect(store.lastLoad == .created)
        #expect(folder.files().isEmpty)
    }

    @Test("a change is written with schemaVersion and reads back equal")
    func roundTrip() throws {
        let folder = try TemporaryDirectory()
        let profileID = UUID()
        let store = SettingsStore(dataDirectory: folder.url)
        let written = try store.update {
            $0.globalModel = ModelSelection(provider: "openrouter", model: "vendor/model")
            $0.shortcut = StoredShortcut(keyCode: 15, modifiers: 6400)
            $0.appDefaults["com.apple.mail"] = profileID
            $0.notifiedProviders = ["openrouter", "openai"]
            $0.acceptedRecipients[profileID] = ["openrouter"]
            $0.killSwitches.copyFallback = false
            $0.customServers = [CustomServer(name: "Ollama", baseURL: URL(string: "http://localhost:11434/v1")!,
                                             requiresAPIKey: false)]
        }
        #expect(try jsonObject(store.url)["schemaVersion"] as? Int == QuillSettings.schemaVersion)
        let reread = SettingsStore(dataDirectory: folder.url)
        #expect(try reread.settings() == written)
        #expect(reread.lastLoad == .loaded)
    }

    @Test("a synthetic version-0 file runs the migration chain and is rewritten at the current version")
    func migratesVersionZero() throws {
        let folder = try TemporaryDirectory()
        // Version 0: no schemaVersion, and the global model under an older key.
        let fixture = #"{"defaultModel": {"provider": "openai", "model": "gpt-x"}, "lastUsedProfile": null}"#
        let url = folder.url.appendingPathComponent("settings.json")
        try Data(fixture.utf8).write(to: url)
        let renameModel = StoreMigration(from: 0) { object in
            object["globalModel"] = object.removeValue(forKey: "defaultModel")
        }
        let store = SettingsStore(dataDirectory: folder.url, migrations: [renameModel])
        let settings = try store.settings()
        #expect(settings.globalModel == ModelSelection(provider: "openai", model: "gpt-x"))
        #expect(store.lastLoad == .migrated(from: 0))
        let rewritten = try jsonObject(url)
        #expect(rewritten["schemaVersion"] as? Int == 1)
        #expect(rewritten["defaultModel"] == nil)
    }

    @Test("the shipped scaffold stamps a version-0 file without changing its values")
    func shippedScaffold() throws {
        let folder = try TemporaryDirectory()
        let url = folder.url.appendingPathComponent("settings.json")
        try Data(#"{"killSwitches": {"copyFallback": false, "manualAccessibility": true, "enhancedAccessibility": true}}"#.utf8)
            .write(to: url)
        let store = SettingsStore(dataDirectory: folder.url)
        #expect(try store.settings().killSwitches.copyFallback == false)
        #expect(try jsonObject(url)["schemaVersion"] as? Int == 1)
    }

    @Test("a corrupt file is moved aside, never overwritten, and the defaults load")
    func quarantinesCorruptFile() throws {
        let folder = try TemporaryDirectory()
        let url = folder.url.appendingPathComponent("settings.json")
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: url)
        let clock = TestClock()
        let store = SettingsStore(dataDirectory: folder.url, files: clock.files)
        #expect(try store.settings() == QuillSettings())
        guard case .quarantined(let moved) = store.lastLoad else {
            Issue.record("expected a quarantine, got \(store.lastLoad)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: moved) == garbage)
        #expect(moved.lastPathComponent.hasPrefix("settings.corrupt-"))

        // A second corrupt file the same second keeps the first one too.
        try garbage.write(to: url)
        store.invalidate()
        _ = try store.settings()
        #expect(folder.files().filter { $0.contains(".corrupt-") }.count == 2)
    }

    @Test("a value that fails validation is quarantined as well")
    func quarantinesInvalidValue() throws {
        let folder = try TemporaryDirectory()
        let url = folder.url.appendingPathComponent("settings.json")
        let invalid = #"{"schemaVersion": 1, "customServers": [{"id": "openai", "name": "X", "baseURL": "http://h", "requiresAPIKey": false}]}"#
        try Data(invalid.utf8).write(to: url)
        let store = SettingsStore(dataDirectory: folder.url)
        _ = try store.settings()
        guard case .quarantined = store.lastLoad else {
            Issue.record("expected a quarantine, got \(store.lastLoad)")
            return
        }
    }

    @Test("a file from a newer Quill is an error and stays where it is")
    func newerSchemaIsLeftAlone() throws {
        let folder = try TemporaryDirectory()
        let url = folder.url.appendingPathComponent("settings.json")
        try Data(#"{"schemaVersion": 99}"#.utf8).write(to: url)
        #expect(throws: StoreError.newerSchema(found: 99, supported: 1)) {
            try SettingsStore(dataDirectory: folder.url).settings()
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("quarantined files are deleted after 30 days, not before")
    func sweepsOldQuarantine() throws {
        let folder = try TemporaryDirectory()
        let clock = TestClock()
        let old = folder.url.appendingPathComponent("old.json")
        try Data("x".utf8).write(to: old)
        let oldMoved = try clock.files.quarantine(old)
        clock.advance(days: 2)
        let recent = folder.url.appendingPathComponent("profiles/p/current.json")
        try FileManager.default.createDirectory(at: recent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: recent)
        let recentMoved = try clock.files.quarantine(recent)

        clock.advance(days: 29)
        let deleted = clock.files.sweepQuarantine(in: folder.url)
        #expect(deleted.map(\.lastPathComponent) == [oldMoved.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: recentMoved.path))
    }

    @Test("an invalid custom server is refused and nothing is written")
    func refusesInvalidServer() throws {
        let folder = try TemporaryDirectory()
        let store = SettingsStore(dataDirectory: folder.url)
        #expect(throws: SettingsError.self) {
            try store.update {
                $0.customServers = [CustomServer(name: "Bad", baseURL: URL(string: "ftp://host")!, requiresAPIKey: false)]
            }
        }
        #expect(folder.files().isEmpty)
        #expect(try store.settings().customServers.isEmpty)
    }

    @Test("forgetting a deleted profile removes every reference to it")
    func forgetsProfile() {
        let gone = UUID()
        let kept = UUID()
        var settings = QuillSettings(appDefaults: ["a": gone, "b": kept], nextRewriteProfile: gone,
                                     lastUsedProfile: gone, acceptedRecipients: [gone: ["openai"], kept: ["openai"]])
        settings.forgetProfile(gone)
        #expect(settings.appDefaults == ["b": kept])
        #expect(settings.nextRewriteProfile == nil && settings.lastUsedProfile == nil)
        #expect(settings.acceptedRecipients.keys.sorted { $0.uuidString < $1.uuidString } == [kept])
    }
}

@Suite("Provider registry rebuilds")
struct RegistryStoreTests {
    @Test("the registry is rebuilt when custom servers change, and only then")
    func rebuildsOnCustomServerChange() throws {
        let folder = try TemporaryDirectory()
        let store = SettingsStore(dataDirectory: folder.url)
        let credentials = InMemoryCredentialStore()
        let holder = try ProviderRegistryHolder(
            shipped: [ChatCompletionsProvider.openAI(credentials: credentials)],
            customServers: try store.settings().customServers,
            makeCustom: { $0.makeProvider(credentials: credentials) })
        holder.follow(store)
        let before = holder.current
        #expect(before.descriptors.map(\.id) == ["openai"])

        try store.update { $0.lastUsedProfile = UUID() }
        #expect(holder.current.descriptors.map(\.id) == ["openai"])

        let server = CustomServer(name: "LM Studio", baseURL: URL(string: "http://127.0.0.1:1234/v1")!,
                                  requiresAPIKey: false)
        try store.update { $0.customServers.append(server) }
        #expect(holder.current.descriptors.map(\.id) == ["openai", server.id])
        #expect(holder.current[server.id]?.descriptor.traits.execution == .onDevice)
        // A rewrite that started earlier keeps its registry.
        #expect(before.descriptors.map(\.id) == ["openai"])

        try store.update { $0.customServers.removeAll() }
        #expect(holder.current.descriptors.map(\.id) == ["openai"])
    }
}

@Suite("Profile store")
struct ProfileStoreTests {
    @Test("a new profile starts at version 1; each edit archives the stored version")
    func versionsEdits() throws {
        let folder = try TemporaryDirectory()
        let clock = TestClock()
        let store = ProfileStore(dataDirectory: folder.url, files: clock.files)
        var work = try store.save(profile())
        #expect(work.version == 1)
        #expect(work.updatedAt == clock.now)

        clock.advance(days: 1)
        work.guidance = "Short sentences."
        work = try store.save(work)
        #expect(work.version == 2)
        #expect(try store.versions(of: work.id).map(\.version) == [1])
        #expect(try store.versions(of: work.id).first?.guidance == "")
        #expect(try store.profile(work.id) == work)
    }

    @Test("saving what is already stored creates no version")
    func identicalSaveIsNoOp() throws {
        let folder = try TemporaryDirectory()
        let store = ProfileStore(dataDirectory: folder.url)
        let work = try store.save(profile())
        let again = try store.save(work)
        #expect(again == work)
        #expect(try store.versions(of: work.id).isEmpty)
    }

    @Test("only the last 20 versions are kept")
    func prunesToTwenty() throws {
        let folder = try TemporaryDirectory()
        let store = ProfileStore(dataDirectory: folder.url)
        var work = try store.save(profile())
        for edit in 1...25 {
            work.guidance = "Edit \(edit)"
            work = try store.save(work)
        }
        #expect(work.version == 26)
        let versions = try store.versions(of: work.id).map(\.version)
        #expect(versions == Array(6...25))
        #expect(versions.count == ProfileStore.keptVersions)
    }

    @Test("revert makes an old version current as a new version")
    func reverts() throws {
        let folder = try TemporaryDirectory()
        let store = ProfileStore(dataDirectory: folder.url)
        var work = try store.save(profile())
        work.guidance = "Changed"
        work = try store.save(work)
        let reverted = try store.revert(work.id, to: 1)
        #expect(reverted.version == 3)
        #expect(reverted.guidance == "")
        #expect(try store.versions(of: work.id).map(\.version) == [1, 2])
        #expect(throws: ProfileStoreError.versionNotFound(work.id, 9)) { try store.revert(work.id, to: 9) }
    }

    @Test("a deleted example is purged from the profile and from every stored version")
    func purgesDeletedExample() throws {
        let folder = try TemporaryDirectory()
        let store = ProfileStore(dataDirectory: folder.url)
        let secret = Example(input: "call me at the office", output: "Call me at the office.")
        let other = Example(input: "see u", output: "See you.")
        var work = try store.save(profile(examples: [secret, other]))
        for edit in 1...3 {
            work.guidance = "Edit \(edit)"
            work = try store.save(work)
        }
        let current = try store.deleteExample(secret.id, from: work.id)
        #expect(current.examples == [other])
        let versions = try store.versions(of: work.id)
        #expect(versions.count == 4)
        #expect(versions.allSatisfy { $0.examples == [other] })
        // Not in any file on disk either.
        for file in folder.files() {
            let text = try String(contentsOf: folder.url.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains("call me at the office"), "found in \(file)")
        }
    }

    @Test("a corrupt profile is quarantined and the others still load")
    func quarantinesCorruptProfile() throws {
        let folder = try TemporaryDirectory()
        let store = ProfileStore(dataDirectory: folder.url)
        let good = try store.save(profile("Good"))
        let bad = try store.save(profile("Bad"))
        let badURL = store.root.appendingPathComponent("\(bad.id.uuidString)/current.json")
        try Data(#"{"schemaVersion": 1, "name": ""}"#.utf8).write(to: badURL)

        let listing = try store.all()
        #expect(listing.profiles.map(\.id) == [good.id])
        #expect(listing.quarantined.count == 1)
        #expect(!FileManager.default.fileExists(atPath: badURL.path))
    }

    @Test("samples are stored beside the profile and capped")
    func samples() throws {
        let folder = try TemporaryDirectory()
        let store = ProfileStore(dataDirectory: folder.url)
        let work = try store.save(profile())
        let set = SampleSet(samples: [Sample(text: "first draft"), Sample(text: "second draft")])
        try store.saveSamples(set, for: work.id)
        #expect(try store.samples(of: work.id) == set)
        let tooMany = SampleSet(samples: (0...ProfileLimits.samples).map { Sample(text: "s\($0)") })
        #expect(throws: ProfileError.tooManySamples(11)) { try store.saveSamples(tooMany, for: work.id) }
    }

    @Test("an exported profile imports under a new id at version 1, with its samples")
    func importsUnderNewID() throws {
        let folder = try TemporaryDirectory()
        let store = ProfileStore(dataDirectory: folder.url)
        var work = try store.save(profile(examples: [Example(input: "see u", output: "See you.")]))
        work.guidance = "Edited"
        work = try store.save(work)
        let samples = SampleSet(samples: [Sample(text: "a sample")])
        try store.saveSamples(samples, for: work.id)

        let exported = try store.export(work.id, includeSamples: true)
        let imported = try store.importProfile(exported)
        #expect(imported.id != work.id)
        #expect(imported.version == 1)
        #expect(imported.guidance == work.guidance && imported.examples == work.examples)
        #expect(try store.samples(of: imported.id) == samples)
        #expect(try store.versions(of: imported.id).isEmpty)
        // The original and its history are untouched.
        #expect(try store.profile(work.id) == work)
        #expect(try store.versions(of: work.id).count == 1)

        let withoutSamples = try store.importProfile(try store.export(work.id, includeSamples: false))
        #expect(try store.samples(of: withoutSamples.id).samples.isEmpty)
    }

    @Test("an import that cannot be read is a typed error")
    func refusesBadImport() throws {
        let folder = try TemporaryDirectory()
        let store = ProfileStore(dataDirectory: folder.url)
        #expect(throws: ProfileStoreError.importFromNewerVersion(found: 7, supported: 1)) {
            try store.importProfile(Data(#"{"schemaVersion": 7}"#.utf8))
        }
        #expect(throws: ProfileStoreError.self) { try store.importProfile(Data("nonsense".utf8)) }
        #expect(try store.all().profiles.isEmpty)
    }

    @Test("built-ins seed an empty store once, and restoring brings back only the deleted ones")
    func builtIns() throws {
        let folder = try TemporaryDirectory()
        let store = ProfileStore(dataDirectory: folder.url)
        #expect(try store.seedIfEmpty(language: "en").count == BuiltInProfile.shipped.count)
        #expect(try store.seedIfEmpty(language: "en").isEmpty)

        let all = try store.all().profiles
        let formal = try #require(all.first { $0.builtIn == .formal })
        var work = try #require(all.first { $0.builtIn == .work })
        work.guidance = "Mine"
        work = try store.save(work)
        try store.delete(formal.id)

        let restored = try store.restoreBuiltIns(language: "en")
        #expect(restored.map(\.builtIn) == [.formal])
        #expect(try store.profile(work.id)?.guidance == "Mine")
        #expect(try store.all().profiles.count == BuiltInProfile.shipped.count)
    }
}

@Suite("Reset Quill")
struct ResetStoreTests {
    @Test("reset leaves no files and no items of the app's Keychain service")
    func resetsEverything() throws {
        let folder = try TemporaryDirectory()
        let settings = SettingsStore(dataDirectory: folder.url)
        try settings.update { $0.lastUsedProfile = UUID() }
        let profiles = ProfileStore(dataDirectory: folder.url)
        try profiles.seedIfEmpty(language: "es")
        let cache = folder.url.appendingPathComponent("cache/models-openai.json")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: cache)
        let credentials = InMemoryCredentialStore(["openai": "test-value", "custom-0a1b2c3d": "test-value"])
        #expect(!folder.files().isEmpty)

        try QuillReset.run(dataDirectory: folder.url, credentials: credentials)
        #expect(folder.files().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).isEmpty)
        #expect(try credentials.secret(for: "openai") == nil)
        #expect(try credentials.secret(for: "custom-0a1b2c3d") == nil)

        settings.invalidate()
        #expect(try settings.settings() == QuillSettings())
    }
}
