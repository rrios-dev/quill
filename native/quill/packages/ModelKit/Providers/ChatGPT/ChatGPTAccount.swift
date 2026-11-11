import Foundation

/// OpenAI's Sign in with ChatGPT for open-source apps: the user signs in in their
/// browser and Quill may then send Responses API requests on the user's ChatGPT plan
/// (quill J-23; https://developers.openai.com/siwc/token-sharing-open-source).
///
/// The endpoints and scopes of that flow, as the docs give them (read 2026-11-11).
public enum ChatGPTPlan {
    public static let providerID: ProviderID = "chatgpt-plan"
    public static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    public static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    public static let issuer = "https://auth.openai.com"
    /// The API the tokens are issued for, sent as `resource` on every grant.
    public static let resource = "https://api.openai.com/v1"
    public static let apiBaseURL = URL(string: "https://api.openai.com/v1")!
    /// The first-time registration entry point; never the client id to save.
    public static let registrationClientID = "dynamic_agent_client"
    /// The permission to use the plan for inference; a valid ID token without it is not enough.
    public static let planScope = "chatgpt.tokens.use.direct"
    public static let scopes = ["openid", "profile", "email", "offline_access", "resource.invoke", planScope]
    /// The loopback callback. Only the port may change between sign-ins.
    public static let callbackPath = "/auth/callback"
    public static let preferredPort: UInt16 = 1455
    /// Where users see and limit each app's use of their plan.
    public static let usageSettingsURL = URL(string: "https://chatgpt.com/#settings/Usage")!
}

/// One ChatGPT account registered on this Mac: who it is, the client OpenAI issued for
/// it, and its tokens. Stored as JSON in the Keychain (`CredentialStore`), never in a file
/// or in defaults, and never logged.
public struct ChatGPTAccount: Codable, Sendable, Hashable {
    public var email: String?
    /// The validated ID token's `sub`.
    public var subject: String
    /// The issued client id (`oaiapp_…`), reused for every later sign-in of this account.
    public var clientID: String
    /// This Mac's host id, sent on every authorization.
    public var hostID: String
    /// Retained for `id_token_hint` on the next sign-in.
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scopes: [String]

    public init(email: String?, subject: String, clientID: String, hostID: String, idToken: String,
                accessToken: String, refreshToken: String?, expiresAt: Date, scopes: [String]) {
        self.email = email
        self.subject = subject
        self.clientID = clientID
        self.hostID = hostID
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    /// Whether the user allowed this app to use their plan.
    public var canUsePlan: Bool { scopes.contains(ChatGPTPlan.planScope) }
}

/// Reads and writes the account record through the injected `CredentialStore`, under the
/// provider's id, plus this Mac's host id under its own entry so it survives a sign-out.
public struct ChatGPTAccountStore: Sendable {
    let credentials: any CredentialStore
    static let hostEntry: ProviderID = "chatgpt-plan.host"

    public init(credentials: any CredentialStore) {
        self.credentials = credentials
    }

    public func load() -> ChatGPTAccount? {
        guard let json = (try? credentials.secret(for: ChatGPTPlan.providerID)) ?? nil else { return nil }
        return try? JSONDecoder.chatGPT.decode(ChatGPTAccount.self, from: Data(json.utf8))
    }

    public func save(_ account: ChatGPTAccount) throws {
        let data = try JSONEncoder.chatGPT.encode(account)
        try credentials.setSecret(String(decoding: data, as: UTF8.self), for: ChatGPTPlan.providerID)
    }

    /// Signs out locally: the tokens go; the host id stays, as the flow asks.
    public func clear() throws {
        try credentials.removeSecret(for: ChatGPTPlan.providerID)
    }

    /// This Mac's stable host id, created on first use: `urn:uuid:` plus a UUIDv4, an
    /// opaque value that identifies no person.
    public func hostID() throws -> String {
        if let saved = (try? credentials.secret(for: Self.hostEntry)) ?? nil, !saved.isEmpty { return saved }
        let id = "urn:uuid:" + UUID().uuidString.lowercased()
        try credentials.setSecret(id, for: Self.hostEntry)
        return id
    }
}

extension JSONEncoder {
    static var chatGPT: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

extension JSONDecoder {
    static var chatGPT: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
