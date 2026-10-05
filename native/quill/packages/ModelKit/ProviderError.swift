import Foundation

/// The only error type that crosses the contract. Each provider maps its
/// vendor's failures onto these codes, so the UI decides what to say from the
/// code alone and never parses a message.
public struct ProviderError: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Code: Sendable, Hashable {
        /// The request is malformed or names a model the provider rejects.
        case invalidRequest
        /// Missing, invalid or revoked credential.
        case authentication
        /// Too many requests or quota exhausted. Retry later.
        case rateLimited(retryAfter: Duration?)
        /// Text plus instructions do not fit the model's context window.
        case contextExceeded
        /// The model or its safety layer declined the content.
        case refused
        /// The provider cannot be used right now (see `ProviderAvailability`).
        case unavailable(UnavailableReason)
        /// No connection, DNS, TLS — the request never got an answer.
        case network
        /// App Transport Security refused a plain-http connection (`-1022`): the server
        /// needs https or a `.local` name (PROVIDERS §4). Not retriable as it stands.
        case insecureConnection
        /// The generation took longer than `GenerationOptions.timeout`.
        case timeout
        /// The provider answered with a server-side failure.
        case server
        /// The provider answered with something we cannot parse.
        case malformedResponse
        /// The caller cancelled. Not a failure: never shown as an error.
        case cancelled
    }

    public var code: Code
    public var message: String
    public var provider: ProviderID?
    /// HTTP status, for remote providers. Diagnostic only.
    public var status: Int?

    public init(_ code: Code, _ message: String, provider: ProviderID? = nil, status: Int? = nil) {
        self.code = code
        self.message = message
        self.provider = provider
        self.status = status
    }

    /// Whether retrying the same request unchanged can succeed.
    public var isRetriable: Bool {
        switch code {
        case .rateLimited, .network, .timeout, .server: true
        default: false
        }
    }

    public var description: String {
        "ProviderError(\(code), provider: \(provider?.rawValue ?? "-"), status: \(status.map(String.init) ?? "-")): \(message)"
    }
}

extension ProviderError {
    /// Maps cancellation from any source (`CancellationError`, `URLError.cancelled`)
    /// onto `.cancelled`, and leaves `ProviderError`s untouched. Anything else
    /// becomes `fallback`.
    public static func normalize(_ error: any Error, provider: ProviderID, fallback: Code = .server) -> ProviderError {
        if let error = error as? ProviderError { return error }
        if error is CancellationError { return ProviderError(.cancelled, "Cancelled.", provider: provider) }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return ProviderError(.cancelled, "Cancelled.", provider: provider)
            case .timedOut: return ProviderError(.timeout, error.localizedDescription, provider: provider)
            case .appTransportSecurityRequiresSecureConnection:
                return ProviderError(.insecureConnection, error.localizedDescription, provider: provider)
            default: return ProviderError(.network, error.localizedDescription, provider: provider)
            }
        }
        return ProviderError(fallback, String(describing: error), provider: provider)
    }
}
