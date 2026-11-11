import Foundation
import Security
import Testing

@testable import ModelKit

/// Sign in with ChatGPT (open-source flow) and the Responses provider on the user's plan.
/// The ID token is signed with a real RSA key made here, so signature checking runs for real.
@Suite("ChatGPT plan")
struct ChatGPTPlanTests {
    static let clientID = "oaiapp_test"
    static let hostID = "urn:uuid:00000000-0000-4000-8000-000000000001"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Authorization URL

    @Test("a first registration asks for the plan scope with PKCE, the host id and the app's name")
    func firstRegistration() throws {
        let signIn = ChatGPTSignIn(transport: ScriptedTransport(.hang), appName: "Quill")
        let (url, pending) = signIn.begin(hostID: Self.hostID, port: 1455)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        #expect(url.absoluteString.hasPrefix("https://auth.openai.com/api/accounts/authorize?"))
        #expect(value("client_id") == "dynamic_agent_client")
        #expect(value("agent_name_hint") == "Quill")
        #expect(value("ext_agent_host_id") == Self.hostID)
        #expect(value("redirect_uri") == "http://127.0.0.1:1455/auth/callback")
        #expect(value("scope")?.split(separator: " ").contains("chatgpt.tokens.use.direct") == true)
        #expect(value("resource") == "https://api.openai.com/v1")
        #expect(value("code_challenge_method") == "S256")
        #expect(value("code_challenge") == ChatGPTSignIn.challenge(for: pending.verifier))
        #expect(value("state") == pending.state)
        #expect(value("id_token_hint") == nil)
        #expect(pending.clientID == nil)
    }

    @Test("signing in again reuses the issued client and hints the account, without the app's name")
    func returningSignIn() throws {
        let signIn = ChatGPTSignIn(transport: ScriptedTransport(.hang), appName: "Quill")
        let (url, pending) = signIn.begin(hostID: Self.hostID, port: 50_000, account: Self.account())
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        #expect(value("client_id") == Self.clientID)
        #expect(value("id_token_hint") == "old-id-token")
        #expect(value("login_hint") == "person@example.com")
        #expect(value("agent_name_hint") == nil)
        #expect(value("redirect_uri") == "http://127.0.0.1:50000/auth/callback", "only the port may change")
        #expect(pending.clientID == Self.clientID)
    }

    /// The expected value comes from `openssl dgst -sha256 -binary | base64`, made url-safe.
    @Test("the PKCE challenge is the unpadded base64url SHA-256 of the verifier")
    func pkce() {
        #expect(ChatGPTSignIn.challenge(for: "dBjftJeZ4CVP-mJ92K9fCaGjdu2ApF7uJn8Cvb5hjaA")
            == "d25IYwaQMBa0-Yf8P71OmifgB-Oe01Kd46SCaulr9sA")
    }

    // MARK: Callback

    @Test("a declined, foreign or incomplete callback is refused before any exchange")
    func refusedCallbacks() async {
        let transport = ScriptedTransport(.hang)
        let signIn = ChatGPTSignIn(transport: transport, appName: "Quill", now: { Self.now })
        let (_, pending) = signIn.begin(hostID: Self.hostID, port: 1455)
        let base = "http://127.0.0.1:1455/auth/callback"

        await #expect(throws: ChatGPTSignIn.Failure.stateMismatch) {
            try await signIn.finish(callback: URL(string: "\(base)?code=c&state=other&client_id=\(Self.clientID)")!, pending: pending)
        }
        await #expect(throws: ChatGPTSignIn.Failure.declined) {
            try await signIn.finish(callback: URL(string: "\(base)?error=access_denied&state=\(pending.state)")!, pending: pending)
        }
        await #expect(throws: ChatGPTSignIn.Failure.registrationIncomplete) {
            try await signIn.finish(callback: URL(string: "\(base)?code=c&state=\(pending.state)")!, pending: pending)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("a valid callback becomes an account: code exchanged with the verifier, ID token verified")
    func completesSignIn() async throws {
        let issuer = try TokenIssuer()
        let signIn = ChatGPTSignIn(transport: issuer.transport(scope: ChatGPTPlan.scopes), appName: "Quill", now: { Self.now })
        let (_, pending) = signIn.begin(hostID: Self.hostID, port: 1455)
        issuer.nonce = pending.nonce

        let account = try await signIn.finish(
            callback: URL(string: "http://127.0.0.1:1455/auth/callback?code=the-code&state=\(pending.state)&client_id=\(Self.clientID)")!,
            pending: pending)

        #expect(account.clientID == Self.clientID)
        #expect(account.subject == "user-123")
        #expect(account.email == "person@example.com")
        #expect(account.accessToken == "access-1")
        #expect(account.refreshToken == "refresh-1")
        #expect(account.expiresAt == Self.now.addingTimeInterval(3600))
        #expect(account.canUsePlan)
        let exchange = try #require(issuer.recorded.first { $0.url == ChatGPTPlan.tokenURL })
        let form = String(decoding: exchange.httpBody ?? Data(), as: UTF8.self)
        #expect(form.contains("code_verifier=\(pending.verifier)"))
        #expect(form.contains("grant_type=authorization_code"))
        #expect(!form.contains("client_secret"))
    }

    @Test("a forged ID token or a wrong nonce is rejected")
    func rejectsBadTokens() async throws {
        let issuer = try TokenIssuer()
        let signIn = ChatGPTSignIn(transport: issuer.transport(scope: ChatGPTPlan.scopes), appName: "Quill", now: { Self.now })
        let (_, pending) = signIn.begin(hostID: Self.hostID, port: 1455)
        let callback = URL(string: "http://127.0.0.1:1455/auth/callback?code=c&state=\(pending.state)&client_id=\(Self.clientID)")!

        issuer.nonce = "someone-elses-nonce"
        await #expect(throws: ChatGPTSignIn.Failure.invalidIDToken("Nonce mismatch.")) {
            try await signIn.finish(callback: callback, pending: pending)
        }
        issuer.nonce = pending.nonce
        issuer.forgeSignature = true
        await #expect(throws: ChatGPTSignIn.Failure.invalidIDToken("Bad signature.")) {
            try await signIn.finish(callback: callback, pending: pending)
        }
    }

    @Test("signing in without allowing the plan is reported, with the account kept apart")
    func planNotAllowed() async throws {
        let issuer = try TokenIssuer()
        let identityOnly = ["openid", "profile", "email", "offline_access"]
        let signIn = ChatGPTSignIn(transport: issuer.transport(scope: identityOnly), appName: "Quill", now: { Self.now })
        let (_, pending) = signIn.begin(hostID: Self.hostID, port: 1455)
        issuer.nonce = pending.nonce

        do {
            _ = try await signIn.finish(
                callback: URL(string: "http://127.0.0.1:1455/auth/callback?code=c&state=\(pending.state)&client_id=\(Self.clientID)")!,
                pending: pending)
            Issue.record("expected planNotAllowed")
        } catch {
            guard case .planNotAllowed(let account) = error else { Issue.record("got \(error)"); return }
            #expect(!account.canUsePlan)
        }
    }

    @Test("the host id is created once and kept across sign-outs")
    func hostID() throws {
        let store = ChatGPTAccountStore(credentials: InMemoryCredentialStore())
        let first = try store.hostID()
        try store.save(Self.account())
        try store.clear()
        #expect(first.hasPrefix("urn:uuid:"))
        #expect(try store.hostID() == first)
        #expect(store.load() == nil)
    }

    // MARK: Session

    @Test("a fresh token is used as is; one near expiry is refreshed once and the rotation saved")
    func refresh() async throws {
        let credentials = InMemoryCredentialStore()
        let store = ChatGPTAccountStore(credentials: credentials)
        var account = Self.account()
        account.expiresAt = Self.now.addingTimeInterval(3600)
        try store.save(account)
        let transport = ScriptedTransport(.lines([#"{"access_token":"access-2","refresh_token":"refresh-2","expires_in":3600}"#]))
        let session = ChatGPTSession(credentials: credentials, transport: transport, now: { Self.now })

        #expect(try await session.accessToken() == "access-1")
        #expect(transport.requests.isEmpty)

        account.expiresAt = Self.now.addingTimeInterval(60)
        try store.save(account)
        async let a = session.accessToken()
        async let b = session.accessToken()
        #expect(try await [a, b] == ["access-2", "access-2"])
        #expect(transport.requests.count == 1, "refreshes are serialized: a rotating token must not race")
        #expect(store.load()?.refreshToken == "refresh-2")
        let form = String(decoding: transport.requests[0].httpBody ?? Data(), as: UTF8.self)
        #expect(form.contains("client_id=\(Self.clientID)"))
        #expect(form.contains("grant_type=refresh_token"))
    }

    @Test("a dead refresh token ends the session and asks to sign in again")
    func deadRefreshToken() async throws {
        let credentials = InMemoryCredentialStore()
        var account = Self.account()
        account.expiresAt = Self.now
        try ChatGPTAccountStore(credentials: credentials).save(account)
        let transport = ScriptedTransport(.status(400, body: #"{"error":"refresh_token_reused"}"#))
        let session = ChatGPTSession(credentials: credentials, transport: transport, now: { Self.now })

        await #expect(throws: ProviderError.self) { try await session.accessToken() }
        #expect(session.account()?.refreshToken == nil)
    }

    // MARK: Provider

    private func provider(_ transport: ScriptedTransport, signedIn: Bool = true) throws -> ChatGPTPlanProvider {
        let credentials = InMemoryCredentialStore()
        if signedIn { try ChatGPTAccountStore(credentials: credentials).save(Self.account()) }
        let session = ChatGPTSession(credentials: credentials, transport: transport, now: { Self.now })
        return ChatGPTPlanProvider(session: session, transport: transport)
    }

    private func request() -> GenerationRequest {
        GenerationRequest(model: "gpt-6.1-sol", instructions: "Fix spelling.", input: "helo",
                          examples: [.init(input: "thx", output: "Thanks")],
                          options: GenerationOptions(temperature: 0.2, maxOutputTokens: 500, timeout: .seconds(5)))
    }

    @Test("streams Responses events into deltas and one result")
    func streams() async throws {
        let provider = try provider(ScriptedTransport(.lines(responsesStream(["Hel", "lo"]))))
        let outcome = await collect(provider.stream(request()))

        #expect(outcome.error == nil)
        #expect(outcome.deltas == ["Hel", "lo"])
        #expect(outcome.result?.text == "Hello")
        #expect(outcome.result?.model == "gpt-6.1-sol-2026")
        #expect(outcome.result?.usage == TokenUsage(inputTokens: 40, outputTokens: 3))
        #expect(outcome.result?.finishReason == .stop)
    }

    @Test("the request follows the preview's rules: no storage, streaming, no temperature or limit")
    func requestShape() async throws {
        let transport = ScriptedTransport(.lines(responsesStream(["ok"])))
        _ = await collect(try provider(transport).stream(request()))

        let sent = try #require(transport.requests.first)
        let body = sent.jsonBody
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["temperature"] == nil)
        #expect(body["max_output_tokens"] == nil)
        #expect(body["instructions"] as? String == "Fix spelling.")
        let input = try #require(body["input"] as? [[String: String]])
        #expect(input == [["role": "user", "content": "thx"], ["role": "assistant", "content": "Thanks"],
                          ["role": "user", "content": "helo"]])
    }

    @Test("signed out: unavailable, and nothing is sent")
    func signedOut() async throws {
        let transport = ScriptedTransport(.lines(responsesStream(["unused"])))
        let provider = try provider(transport, signedIn: false)

        #expect(await provider.availability() == .unavailable(.notSignedIn))
        #expect(await collect(provider.stream(request())).error?.code == .unavailable(.notSignedIn))
        #expect(transport.requests.isEmpty)
    }

    @Test("the plan's usage limit, mid-stream, maps to .rateLimited")
    func usageLimit() async throws {
        let failed = [#"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"Limit"}}}"#]
        let outcome = await collect(try provider(ScriptedTransport(.lines(failed))).stream(request()))
        #expect(outcome.error?.code == .rateLimited(retryAfter: nil))
    }

    @Test("Responses errors map to the contract", arguments: [
        ("subscription_sharing_user_not_eligible", 403, ProviderError.Code.unavailable(.planNotEligible)),
        ("subscription_sharing_invalid_user", 401, .unavailable(.notSignedIn)),
        ("subscription_sharing_usage_unavailable", 503, .server),
        ("subscription_sharing_unsupported_capability", 400, .invalidRequest),
    ])
    func errorMapping(_ code: String, _ status: Int, _ expected: ProviderError.Code) {
        let body = Data(#"{"error":{"code":"\#(code)","message":"m"}}"#.utf8)
        #expect(ChatGPTPlanProvider.mapHTTPError(status: status, body: body, provider: ChatGPTPlan.providerID).code == expected)
    }

    @Test("a 401 is retried once with a refreshed token")
    func retriesAfterRejection() async throws {
        let transport = ScriptedTransport { request in
            if request.url == ChatGPTPlan.tokenURL {
                return .lines([#"{"access_token":"access-2","refresh_token":"refresh-2","expires_in":3600}"#])
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1"
                ? .status(401, body: #"{"detail":"expired"}"#) : .lines(responsesStream(["ok"]))
        }
        let outcome = await collect(try provider(transport).stream(request()))
        #expect(outcome.result?.text == "ok")
        #expect(transport.requests.count == 3)
    }

    @Test("the model list keeps listed models, recommended first")
    func models() async throws {
        let list = #"{"models":[{"slug":"gpt-6.1-sol","display_name":"GPT-6.1 Sol","visibility":"list"},{"slug":"hidden","visibility":"hide"},{"slug":"gpt-6-mini","display_name":"GPT-6 mini","visibility":"list"}]}"#
        let credentials = InMemoryCredentialStore()
        try ChatGPTAccountStore(credentials: credentials).save(Self.account())
        let transport = ScriptedTransport(.lines([list]))
        let provider = ChatGPTPlanProvider(session: ChatGPTSession(credentials: credentials, transport: transport, now: { Self.now }),
                                           transport: transport, recommended: ["gpt-6-mini"])
        let models = try await provider.models()
        #expect(models.map(\.id) == ["gpt-6-mini", "gpt-6.1-sol"])
        #expect(models.last?.displayName == "GPT-6.1 Sol")
    }

    // MARK: Fixtures

    static func account() -> ChatGPTAccount {
        ChatGPTAccount(email: "person@example.com", subject: "user-123", clientID: clientID, hostID: hostID,
                       idToken: "old-id-token", accessToken: "access-1", refreshToken: "refresh-1",
                       expiresAt: now.addingTimeInterval(3600), scopes: ChatGPTPlan.scopes)
    }
}

/// The Responses API's server-sent events for `pieces`, ending in `response.completed`.
func responsesStream(_ pieces: [String]) -> [String] {
    var lines = [#"event: response.created"#, #"data: {"type":"response.created"}"#, ""]
    for piece in pieces {
        lines += ["event: response.output_text.delta", #"data: {"type":"response.output_text.delta","delta":"\#(piece)"}"#, ""]
    }
    lines += ["event: response.completed",
              #"data: {"type":"response.completed","response":{"model":"gpt-6.1-sol-2026","status":"completed","usage":{"input_tokens":40,"output_tokens":3}}}"#, ""]
    return lines
}

/// An OpenAI-shaped authorization server with a real RSA key: discovery, key set, and a
/// token endpoint returning an ID token signed with it.
final class TokenIssuer: @unchecked Sendable {
    private let privateKey: SecKey
    private let lock = NSLock()
    private var nonceValue = ""
    private var forged = false
    private var requests: [URLRequest] = []

    var nonce: String { get { lock.withLock { nonceValue } } set { lock.withLock { nonceValue = newValue } } }
    var forgeSignature: Bool { get { lock.withLock { forged } } set { lock.withLock { forged = newValue } } }
    var recorded: [URLRequest] { lock.withLock { requests } }

    init() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw error!.takeRetainedValue() }
        privateKey = key
    }

    func transport(scope: [String]) -> ScriptedTransport {
        ScriptedTransport { [self] request in
            lock.withLock { requests.append(request) }
            switch request.url?.absoluteString {
            case ChatGPTPlan.discoveryURL.absoluteString:
                return .lines([#"{"issuer":"https://auth.openai.com","jwks_uri":"https://auth.openai.com/jwks.json"}"#])
            case "https://auth.openai.com/jwks.json":
                return .lines([jwks()])
            case ChatGPTPlan.tokenURL.absoluteString:
                let body = #"{"access_token":"access-1","refresh_token":"refresh-1","id_token":"\#(idToken())","expires_in":3600,"scope":"\#(scope.joined(separator: " "))"}"#
                return .lines([body])
            default:
                return .status(404, body: "")
            }
        }
    }

    private func jwks() -> String {
        let der = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data
        let (modulus, exponent) = Self.parsePKCS1(der)
        return #"{"keys":[{"kty":"RSA","kid":"k1","alg":"RS256","n":"\#(modulus.base64URLEncodedString())","e":"\#(exponent.base64URLEncodedString())"}]}"#
    }

    private func idToken() -> String {
        let header = Data(#"{"alg":"RS256","kid":"k1","typ":"JWT"}"#.utf8).base64URLEncodedString()
        let exp = Int(ChatGPTPlanTests.now.timeIntervalSince1970) + 3600
        let payload = Data(#"{"iss":"https://auth.openai.com","sub":"user-123","aud":["\#(ChatGPTPlanTests.clientID)"],"exp":\#(exp),"nonce":"\#(nonce)","email":"person@example.com"}"#.utf8)
            .base64URLEncodedString()
        let signed = Data("\(header).\(payload)".utf8)
        var signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, nil)! as Data
        if forgeSignature { signature[signature.startIndex] ^= 0xFF }
        return "\(header).\(payload).\(signature.base64URLEncodedString())"
    }

    /// Modulus and exponent of a PKCS #1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }.
    static func parsePKCS1(_ der: Data) -> (Data, Data) {
        var bytes = [UInt8](der)[...]
        func length() -> Int {
            let first = Int(bytes.removeFirst())
            guard first & 0x80 != 0 else { return first }
            return (0..<(first & 0x7F)).reduce(0) { value, _ in (value << 8) | Int(bytes.removeFirst()) }
        }
        func integer() -> Data {
            _ = bytes.removeFirst()
            let count = length()
            let value = Data(bytes.prefix(count))
            bytes = bytes.dropFirst(count)
            return value
        }
        _ = bytes.removeFirst()
        _ = length()
        return (integer(), integer())
    }
}
