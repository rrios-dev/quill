import CryptoKit
import Foundation
import Security

/// The open-source registration and sign-in flow of Sign in with ChatGPT: build the
/// browser URL, then turn the loopback callback into a validated `ChatGPTAccount`.
///
/// Opening the browser and listening on the loopback port belong to the caller (the app
/// opens the URL; `LoopbackCallbackServer` waits for the callback), so every step here
/// runs against a scripted transport in tests.
public struct ChatGPTSignIn: Sendable {
    let transport: any HTTPTransport
    /// The app's name, shown to the user when they authorize it the first time.
    let appName: String
    let now: @Sendable () -> Date

    public init(transport: any HTTPTransport = URLSessionTransport(), appName: String,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.appName = appName
        self.now = now
    }

    /// One authorization attempt: fresh state, nonce and PKCE verifier, and the exact
    /// callback URI, kept until the callback completes.
    public struct Pending: Sendable, Hashable {
        public var state: String
        public var nonce: String
        public var verifier: String
        public var redirectURI: URL
        /// The issued client id when this account signed in before; `nil` for a first registration.
        public var clientID: String?
        public var hostID: String
    }

    public enum Failure: Error, Sendable, Hashable {
        /// The user declined in the browser.
        case declined
        /// The callback does not belong to this attempt.
        case stateMismatch
        /// A first registration came back without an issued client id.
        case registrationIncomplete
        /// The callback names another client than the account's own.
        case clientMismatch
        /// The code could not be exchanged; start again.
        case exchange(String)
        /// The ID token failed validation.
        case invalidIDToken(String)
        /// Signed in, but the user did not allow using their plan.
        case planNotAllowed(ChatGPTAccount)
        /// The account signed in is not the one being renewed.
        case differentAccount
    }

    /// The URL to open in the system browser, and the attempt to keep until the callback.
    /// `account` is the saved registration when signing in again.
    public func begin(hostID: String, port: UInt16, account: ChatGPTAccount? = nil) -> (url: URL, pending: Pending) {
        let pending = Pending(state: Self.random(), nonce: Self.random(), verifier: Self.random(bytes: 48),
                              redirectURI: URL(string: "http://127.0.0.1:\(port)\(ChatGPTPlan.callbackPath)")!,
                              clientID: account?.clientID, hostID: hostID)
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: account?.clientID ?? ChatGPTPlan.registrationClientID),
            .init(name: "ext_agent_host_id", value: hostID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: pending.redirectURI.absoluteString),
            .init(name: "scope", value: ChatGPTPlan.scopes.joined(separator: " ")),
            .init(name: "resource", value: ChatGPTPlan.resource),
            .init(name: "state", value: pending.state),
            .init(name: "nonce", value: pending.nonce),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: Self.challenge(for: pending.verifier)),
        ]
        if let account {
            items.append(.init(name: "id_token_hint", value: account.idToken))
            if let email = account.email { items.append(.init(name: "login_hint", value: email)) }
        } else {
            items.append(.init(name: "agent_name_hint", value: appName))
        }
        var components = URLComponents(url: ChatGPTPlan.authorizeURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: .urlQueryValue))
        }
        return (components.url!, pending)
    }

    /// Validates the callback, exchanges the code and the ID token, and returns the
    /// account. `previous` is the account being renewed, whose identity must match.
    public func finish(callback: URL, pending: Pending, previous: ChatGPTAccount? = nil) async throws(Failure) -> ChatGPTAccount {
        let query = Dictionary(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?
            .compactMap { item in item.value.map { (item.name, $0) } } ?? [], uniquingKeysWith: { first, _ in first })
        guard query["state"] == pending.state else { throw .stateMismatch }
        if query["error"] != nil { throw .declined }
        guard let code = query["code"] else { throw .exchange("The callback carries no code.") }
        let clientID: String
        if let saved = pending.clientID {
            if let returned = query["client_id"], returned != saved { throw .clientMismatch }
            clientID = saved
        } else {
            guard let issued = query["client_id"], issued != ChatGPTPlan.registrationClientID else {
                throw .registrationIncomplete
            }
            clientID = issued
        }

        let tokens = try await exchange([
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "code_verifier": pending.verifier, "redirect_uri": pending.redirectURI.absoluteString,
            "resource": ChatGPTPlan.resource,
        ])
        guard let idToken = tokens.idToken else { throw .invalidIDToken("The token response has no ID token.") }
        let claims = try await validate(idToken: idToken, clientID: clientID, nonce: pending.nonce)
        if let previous, previous.subject != claims.sub { throw .differentAccount }

        let account = ChatGPTAccount(
            email: claims.email ?? previous?.email, subject: claims.sub, clientID: clientID, hostID: pending.hostID,
            idToken: idToken, accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(tokens.expiresIn ?? 3600)),
            scopes: (tokens.scope ?? query["scope"] ?? "").split(separator: " ").map(String.init))
        guard account.canUsePlan else { throw .planNotAllowed(account) }
        return account
    }

    // MARK: Sign-out

    /// Ends the renewable session at OpenAI (the discovery document's revocation
    /// endpoint). Returns whether the revocation was confirmed; the caller clears the
    /// local tokens either way and says so when it was not.
    public func revoke(_ account: ChatGPTAccount) async -> Bool {
        guard let refreshToken = account.refreshToken,
              let (discovery, _) = try? await transport.data(for: URLRequest(url: ChatGPTPlan.discoveryURL)),
              let object = try? JSONSerialization.jsonObject(with: discovery) as? [String: Any],
              let endpoint = (object["revocation_endpoint"] as? String).flatMap(URL.init(string:)) else { return false }
        let request = Self.formRequest(endpoint, ["token": refreshToken, "token_type_hint": "refresh_token",
                                                  "client_id": account.clientID])
        // An empty 200 is success, including for a token that was already invalid.
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(attempt)) }
            guard let (_, response) = try? await transport.data(for: request) else { continue }
            if (200..<300).contains(response.statusCode) { return true }
            if response.statusCode < 500 { return false }
        }
        return false
    }

    // MARK: Token endpoint

    struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var expiresIn: Int?
        var scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token"
            case expiresIn = "expires_in", scope
        }
    }

    func exchange(_ form: [String: String]) async throws(Failure) -> TokenResponse {
        do {
            let (data, response) = try await transport.data(for: Self.formRequest(ChatGPTPlan.tokenURL, form))
            guard (200..<300).contains(response.statusCode) else {
                throw Failure.exchange("HTTP \(response.statusCode): \(String(decoding: data.prefix(300), as: UTF8.self))")
            }
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .exchange(String(describing: error))
        }
    }

    static func formRequest(_ url: URL, _ form: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValue) ?? "")" }
            .joined(separator: "&").utf8)
        return request
    }

    // MARK: ID token

    struct Claims: Decodable {
        var iss: String
        var sub: String
        var aud: Audience
        var exp: Double
        var nonce: String?
        var email: String?

        /// `aud` is a string or an array of strings.
        struct Audience: Decodable {
            var values: [String]
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let list = try? container.decode([String].self) {
                    values = list
                } else {
                    values = [try container.decode(String.self)]
                }
            }
        }
    }

    /// Signature against OpenAI's published keys (RS256), then issuer, audience, expiry and nonce.
    func validate(idToken: String, clientID: String, nonce: String) async throws(Failure) -> Claims {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = Data(base64URL: parts[0]), let payloadData = Data(base64URL: parts[1]),
              let signature = Data(base64URL: parts[2]),
              let header = try? JSONDecoder().decode(JWTHeader.self, from: headerData),
              let claims = try? JSONDecoder().decode(Claims.self, from: payloadData) else {
            throw .invalidIDToken("Unreadable token.")
        }
        guard header.alg == "RS256" else { throw .invalidIDToken("Unexpected algorithm \(header.alg).") }
        let key = try await signingKey(id: header.kid)
        var error: Unmanaged<CFError>?
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data("\(parts[0]).\(parts[1])".utf8) as CFData,
                                    signature as CFData, &error) else {
            throw .invalidIDToken("Bad signature.")
        }
        guard claims.iss == ChatGPTPlan.issuer else { throw .invalidIDToken("Unexpected issuer.") }
        guard claims.aud.values.contains(clientID) else { throw .invalidIDToken("Issued for another client.") }
        guard Date(timeIntervalSince1970: claims.exp) > now() else { throw .invalidIDToken("Expired.") }
        guard claims.nonce == nonce else { throw .invalidIDToken("Nonce mismatch.") }
        return claims
    }

    struct JWTHeader: Decodable {
        var alg: String
        var kid: String?
    }

    struct JWKSet: Decodable {
        struct Key: Decodable {
            var kid: String?
            var kty: String
            var n: String?
            var e: String?
        }
        var keys: [Key]
    }

    func signingKey(id: String?) async throws(Failure) -> SecKey {
        do {
            let (discovery, _) = try await transport.data(for: URLRequest(url: ChatGPTPlan.discoveryURL))
            guard let jwksURI = (try JSONSerialization.jsonObject(with: discovery) as? [String: Any])?["jwks_uri"] as? String,
                  let url = URL(string: jwksURI) else { throw Failure.invalidIDToken("No key set published.") }
            let (data, _) = try await transport.data(for: URLRequest(url: url))
            let set = try JSONDecoder().decode(JWKSet.self, from: data)
            guard let jwk = set.keys.first(where: { $0.kty == "RSA" && (id == nil || $0.kid == id) }),
                  let modulus = jwk.n.flatMap(Data.init(base64URL:)), let exponent = jwk.e.flatMap(Data.init(base64URL:)) else {
                throw Failure.invalidIDToken("No matching signing key.")
            }
            return try Self.rsaPublicKey(modulus: modulus, exponent: exponent)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .invalidIDToken("Key set unavailable: \(error)")
        }
    }

    /// A Security framework RSA key from a JWK's modulus and exponent (PKCS #1 DER).
    static func rsaPublicKey(modulus: Data, exponent: Data) throws(Failure) -> SecKey {
        func integer(_ bytes: Data) -> Data {
            var bytes = Data(bytes.drop { $0 == 0 })
            if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
            return der(tag: 0x02, bytes)
        }
        let sequence = der(tag: 0x30, integer(modulus) + integer(exponent))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(sequence as CFData, attributes as CFDictionary, nil) else {
            throw .invalidIDToken("Unusable signing key.")
        }
        return key
    }

    static func der(tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        if content.count < 0x80 {
            out.append(UInt8(content.count))
        } else {
            let length = withUnsafeBytes(of: UInt32(content.count).bigEndian) { Data($0) }.drop { $0 == 0 }
            out.append(0x80 | UInt8(length.count))
            out.append(contentsOf: length)
        }
        return out + content
    }

    // MARK: PKCE and random values

    static func random(bytes count: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    /// The base64url SHA-256 of the verifier, without padding.
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
}

extension Data {
    init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension CharacterSet {
    /// Unreserved characters only, so `+`, `&`, `=` and spaces in values are encoded.
    static let urlQueryValue = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
