import Foundation

/// Hands out a valid access token for the signed-in ChatGPT account, refreshing it near
/// expiry. Refreshes are serialized, because each one rotates the refresh token and two
/// racing refreshes would invalidate each other.
public actor ChatGPTSession {
    private let store: ChatGPTAccountStore
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private var refreshing: Task<ChatGPTAccount, any Error>?

    /// Refresh this long before the access token expires.
    static let margin: TimeInterval = 5 * 60

    public init(credentials: any CredentialStore, transport: any HTTPTransport = URLSessionTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = ChatGPTAccountStore(credentials: credentials)
        self.transport = transport
        self.now = now
    }

    /// The account that can use its plan, or `nil`.
    public nonisolated func account() -> ChatGPTAccount? {
        store.load().flatMap { $0.canUsePlan ? $0 : nil }
    }

    /// A token valid for at least the margin. Throws `.unavailable(.notSignedIn)` when
    /// there is no usable session, so the user is asked to sign in again.
    public func accessToken() async throws -> String {
        guard let account = store.load(), account.canUsePlan else {
            throw ProviderError(.unavailable(.notSignedIn), "No ChatGPT account is signed in.", provider: ChatGPTPlan.providerID)
        }
        if account.expiresAt.timeIntervalSince(now()) > Self.margin { return account.accessToken }
        return try await refresh(account).accessToken
    }

    /// Forces a refresh, after the API rejected a token that looked valid.
    public func refreshAfterRejection() async throws -> String {
        guard let account = store.load() else {
            throw ProviderError(.unavailable(.notSignedIn), "No ChatGPT account is signed in.", provider: ChatGPTPlan.providerID)
        }
        return try await refresh(account).accessToken
    }

    private func refresh(_ account: ChatGPTAccount) async throws -> ChatGPTAccount {
        if let refreshing { return try await refreshing.value }
        let task = Task { try await performRefresh(account) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    /// Codes that mean the refresh token can never work again (Errors and recovery).
    static let terminalRefreshErrors: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
        "refresh_token_invalidated", "refresh_token_reused",
    ]

    private func performRefresh(_ account: ChatGPTAccount) async throws -> ChatGPTAccount {
        let provider = ChatGPTPlan.providerID
        guard let refreshToken = account.refreshToken else {
            throw ProviderError(.unavailable(.notSignedIn), "The session cannot be renewed.", provider: provider)
        }
        let request = ChatGPTSignIn.formRequest(ChatGPTPlan.tokenURL, [
            "grant_type": "refresh_token", "client_id": account.clientID, "refresh_token": refreshToken,
            "resource": ChatGPTPlan.resource,
        ])
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw ProviderError.normalize(error, provider: provider, fallback: .network)
        }
        guard (200..<300).contains(response.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            if let code, Self.terminalRefreshErrors.contains(code) {
                // The tokens are dead; the registration and host id stay for the next sign-in.
                var cleared = account
                cleared.accessToken = ""
                cleared.refreshToken = nil
                cleared.expiresAt = .distantPast
                try? store.save(cleared)
                throw ProviderError(.unavailable(.notSignedIn), "The ChatGPT session ended (\(code)).", provider: provider,
                                    status: response.statusCode)
            }
            throw ProviderError(response.statusCode >= 500 ? .server : .authentication,
                                "Refresh failed: HTTP \(response.statusCode).", provider: provider, status: response.statusCode)
        }
        let tokens: ChatGPTSignIn.TokenResponse
        do {
            tokens = try JSONDecoder().decode(ChatGPTSignIn.TokenResponse.self, from: data)
        } catch {
            throw ProviderError(.malformedResponse, "Unreadable refresh answer.", provider: provider)
        }
        var renewed = account
        renewed.accessToken = tokens.accessToken
        renewed.refreshToken = tokens.refreshToken ?? account.refreshToken
        renewed.expiresAt = now().addingTimeInterval(TimeInterval(tokens.expiresIn ?? 3600))
        if let scope = tokens.scope { renewed.scopes = scope.split(separator: " ").map(String.init) }
        if let idToken = tokens.idToken { renewed.idToken = idToken }
        try? store.save(renewed)
        return renewed
    }
}
