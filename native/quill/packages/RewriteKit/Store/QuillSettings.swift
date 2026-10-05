import Foundation
import ModelKit

/// Everything `settings.json` holds (ARCHITECTURE §4.2).
///
/// Plain values only: the shortcut is a key code and Carbon modifiers, the kill
/// switches are booleans, so RewriteKit stays free of AppKit and SelectionKit. The app
/// converts them at its edges.
public struct QuillSettings: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    /// The global model; nil until the user (or onboarding) chooses one.
    public var globalModel: ModelSelection?
    /// nil uses the default shortcut (README Q4).
    public var shortcut: StoredShortcut?
    /// Bundle id → the profile used there by default (PRODUCT §4.1, the Apps pane).
    public var appDefaults: [String: UUID]
    /// Bundle ids whose default applies directly, without the picker (PRODUCT F2).
    public var directApplyApps: Set<String>
    /// The menu bar's choice for the next rewrite only; cleared when used (ARCHITECTURE §5.3).
    public var nextRewriteProfile: UUID?
    public var lastUsedProfile: UUID?
    public var customServers: [CustomServer]
    /// Hosted providers whose one-time notice the user has accepted (ARCHITECTURE §6).
    public var notifiedProviders: Set<ProviderID>
    /// Profile id → providers its user-authored text may go to (ARCHITECTURE §5.3).
    public var acceptedRecipients: [UUID: Set<ProviderID>]
    public var killSwitches: KillSwitches
    /// Onboarding finished (PRODUCT F4); until then it opens at launch.
    public var onboardingCompleted: Bool

    public init(
        globalModel: ModelSelection? = nil, shortcut: StoredShortcut? = nil, appDefaults: [String: UUID] = [:],
        directApplyApps: Set<String> = [], nextRewriteProfile: UUID? = nil, lastUsedProfile: UUID? = nil, customServers: [CustomServer] = [],
        notifiedProviders: Set<ProviderID> = [], acceptedRecipients: [UUID: Set<ProviderID>] = [:],
        killSwitches: KillSwitches = KillSwitches(), onboardingCompleted: Bool = false
    ) {
        self.globalModel = globalModel
        self.shortcut = shortcut
        self.appDefaults = appDefaults
        self.directApplyApps = directApplyApps
        self.nextRewriteProfile = nextRewriteProfile
        self.lastUsedProfile = lastUsedProfile
        self.customServers = customServers
        self.notifiedProviders = notifiedProviders
        self.acceptedRecipients = acceptedRecipients
        self.killSwitches = killSwitches
        self.onboardingCompleted = onboardingCompleted
    }

    /// Every rule a saved file must satisfy; a file that breaks one is quarantined.
    public func validate() throws(SettingsError) {
        var ids = Set<ProviderID>()
        for server in customServers {
            try server.validate()
            guard ids.insert(server.id).inserted else { throw .duplicateCustomServer(server.id) }
        }
    }

    /// Forgets a deleted profile everywhere it is referenced (ARCHITECTURE §5.3: the
    /// mapping is removed when the profile is deleted).
    public mutating func forgetProfile(_ id: UUID) {
        appDefaults = appDefaults.filter { $0.value != id }
        if nextRewriteProfile == id { nextRewriteProfile = nil }
        if lastUsedProfile == id { lastUsedProfile = nil }
        acceptedRecipients[id] = nil
    }

    enum CodingKeys: String, CodingKey {
        case globalModel, shortcut, appDefaults, directApplyApps, nextRewriteProfile, lastUsedProfile, customServers,
             notifiedProviders, acceptedRecipients, killSwitches, onboardingCompleted
    }

    // Dictionaries keyed by UUID would encode as flat arrays; they are written keyed by
    // the UUID's string, and sets as sorted arrays so the file diffs cleanly.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        globalModel = try container.decodeIfPresent(ModelSelection.self, forKey: .globalModel)
        shortcut = try container.decodeIfPresent(StoredShortcut.self, forKey: .shortcut)
        appDefaults = try container.decodeIfPresent([String: UUID].self, forKey: .appDefaults) ?? [:]
        directApplyApps = Set(try container.decodeIfPresent([String].self, forKey: .directApplyApps) ?? [])
        nextRewriteProfile = try container.decodeIfPresent(UUID.self, forKey: .nextRewriteProfile)
        lastUsedProfile = try container.decodeIfPresent(UUID.self, forKey: .lastUsedProfile)
        customServers = try container.decodeIfPresent([CustomServer].self, forKey: .customServers) ?? []
        notifiedProviders = Set(try container.decodeIfPresent([ProviderID].self, forKey: .notifiedProviders) ?? [])
        let recipients = try container.decodeIfPresent([String: [ProviderID]].self, forKey: .acceptedRecipients) ?? [:]
        var accepted: [UUID: Set<ProviderID>] = [:]
        for (key, value) in recipients {
            guard let id = UUID(uuidString: key) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .acceptedRecipients, in: container, debugDescription: "Not a profile id: \(key)")
            }
            accepted[id] = Set(value)
        }
        acceptedRecipients = accepted
        killSwitches = try container.decodeIfPresent(KillSwitches.self, forKey: .killSwitches) ?? KillSwitches()
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(globalModel, forKey: .globalModel)
        try container.encodeIfPresent(shortcut, forKey: .shortcut)
        try container.encode(appDefaults, forKey: .appDefaults)
        try container.encode(directApplyApps.sorted(), forKey: .directApplyApps)
        try container.encodeIfPresent(nextRewriteProfile, forKey: .nextRewriteProfile)
        try container.encodeIfPresent(lastUsedProfile, forKey: .lastUsedProfile)
        try container.encode(customServers, forKey: .customServers)
        try container.encode(notifiedProviders.sorted { $0.rawValue < $1.rawValue }, forKey: .notifiedProviders)
        let recipients = Dictionary(uniqueKeysWithValues: acceptedRecipients.map { key, value in
            (key.uuidString, value.sorted { $0.rawValue < $1.rawValue })
        })
        try container.encode(recipients, forKey: .acceptedRecipients)
        try container.encode(killSwitches, forKey: .killSwitches)
        try container.encode(onboardingCompleted, forKey: .onboardingCompleted)
    }
}

/// A global shortcut as AppCore's `KeyCombination` stores it: a virtual key code and
/// Carbon modifier flags.
public struct StoredShortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// The switches that turn off a capture technique (ARCHITECTURE §3.1, PLAN P4-T5).
public struct KillSwitches: Codable, Hashable, Sendable {
    public var copyFallback = true
    public var manualAccessibility = true
    public var enhancedAccessibility = true

    public init(copyFallback: Bool = true, manualAccessibility: Bool = true, enhancedAccessibility: Bool = true) {
        self.copyFallback = copyFallback
        self.manualAccessibility = manualAccessibility
        self.enhancedAccessibility = enhancedAccessibility
    }
}

/// A server the user added that speaks Chat Completions: Ollama, LM Studio, a company
/// gateway (PROVIDERS §4). Its key, when it needs one, is in the Keychain under its id.
public struct CustomServer: Codable, Hashable, Identifiable, Sendable {
    public static let idPrefix = "custom-"

    public var id: ProviderID
    /// 1–40 characters.
    public var name: String
    public var baseURL: URL
    public var requiresAPIKey: Bool

    public init(id: ProviderID = CustomServer.newID(), name: String, baseURL: URL, requiresAPIKey: Bool) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.requiresAPIKey = requiresAPIKey
    }

    /// `custom-<8 hex>`: well formed, and never one of the shipped ids.
    public static func newID() -> ProviderID {
        ProviderID(rawValue: idPrefix + UUID().uuidString.lowercased().prefix(8))
    }

    public func validate() throws(SettingsError) {
        guard id.isWellFormed, id.rawValue.hasPrefix(Self.idPrefix) else { throw .invalidCustomServerID(id) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, name.count <= ProfileLimits.nameCharacters else { throw .invalidCustomServerName(name) }
        guard let scheme = baseURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = baseURL.host(), !host.isEmpty
        else { throw .invalidCustomServerURL(baseURL.absoluteString) }
    }

    /// The provider the registry holds for this server.
    public func makeProvider(credentials: any CredentialStore,
                             transport: any HTTPTransport = URLSessionTransport()) -> ChatCompletionsProvider {
        .custom(id: id, displayName: name, baseURL: baseURL, requiresAPIKey: requiresAPIKey,
                credentials: credentials, transport: transport)
    }
}

public enum SettingsError: Error, Hashable, Sendable {
    case invalidCustomServerID(ProviderID)
    case invalidCustomServerName(String)
    case invalidCustomServerURL(String)
    case duplicateCustomServer(ProviderID)
}
