import Foundation
import Security

/// Where API keys live. Providers receive a store and read from it on every
/// call; they never keep a key in memory longer than one request.
public protocol CredentialStore: Sendable {
    func secret(for provider: ProviderID) throws -> String?
    func setSecret(_ secret: String, for provider: ProviderID) throws
    func removeSecret(for provider: ProviderID) throws
    /// Removes every key of this store — including those of custom servers no longer
    /// listed anywhere ("Reset", PROVIDERS §8 item 8).
    func removeAll() throws
}

/// API keys in the login Keychain, one generic-password item per provider.
///
/// Never `UserDefaults`: that is a plain plist any process running as the user
/// can read, and it ends up in backups in the clear.
public struct KeychainCredentialStore: CredentialStore {
    /// The Keychain service: one per consumer, fixed and never renamed with the product
    /// (ARCHITECTURE §4.2) — `quill.providers` for the app (debug builds with an
    /// overridden bundle id use `quill.providers.<suffix>`), `quill.bench` for the bench.
    /// Each consumer reads and deletes only its own service's items.
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func secret(for provider: ProviderID) throws -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func setSecret(_ secret: String, for provider: ProviderID) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(baseQuery(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = baseQuery(provider)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func removeSecret(for provider: ProviderID) throws {
        let status = SecItemDelete(baseQuery(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public func removeAll() throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ provider: ProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}

public struct KeychainError: Error, Sendable, Hashable {
    public let status: OSStatus
}

/// For tests and previews. Thread-safe so it can be shared across tasks.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [ProviderID: String]

    public init(_ secrets: [ProviderID: String] = [:]) {
        self.secrets = secrets
    }

    public func secret(for provider: ProviderID) throws -> String? {
        lock.withLock { secrets[provider] }
    }

    public func setSecret(_ secret: String, for provider: ProviderID) throws {
        lock.withLock { secrets[provider] = secret }
    }

    public func removeSecret(for provider: ProviderID) throws {
        lock.withLock { secrets[provider] = nil }
    }

    public func removeAll() throws {
        lock.withLock { secrets.removeAll() }
    }
}
