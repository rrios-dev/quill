import Foundation

/// The rule a custom server's address follows (PROVIDERS §4): https anywhere; plain http
/// only to this Mac (loopback, measured to need no exception) or to a `.local` name, which
/// `NSAllowsLocalNetworking` exempts from App Transport Security. Plain http to an IP
/// address is refused before it is saved: ATS blocks it whatever the setting
/// (measured: `-1022`), so the server could never work.
public enum ServerAddress {
    public enum Problem: Error, Equatable, Sendable {
        /// Not a URL with a scheme and a host.
        case notAURL
        /// Neither http nor https.
        case unsupportedScheme(String)
        /// Plain http to an IP address that is not loopback.
        case plainHTTPToAddress(String)
        /// Plain http to a name that is neither loopback nor `.local`.
        case plainHTTPToRemoteName(String)
    }

    public enum Kind: Equatable, Sendable {
        /// On this Mac: classified as on-device and free (with its forwarding note).
        case loopback
        /// A server on the local network, by its `.local` name.
        case localNetwork
        /// https to anywhere.
        case secure
    }

    public static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// Checks what the user typed. Accepts a missing `/v1` as typed — servers differ.
    public static func check(_ text: String) -> Result<(url: URL, kind: Kind), Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
        else { return .failure(.notAURL) }
        switch scheme {
        case "https":
            return .success((url, loopbackHosts.contains(host) ? .loopback : .secure))
        case "http":
            if loopbackHosts.contains(host) { return .success((url, .loopback)) }
            if host.hasSuffix(".local") { return .success((url, .localNetwork)) }
            if isIPAddress(host) { return .failure(.plainHTTPToAddress(host)) }
            return .failure(.plainHTTPToRemoteName(host))
        default:
            return .failure(.unsupportedScheme(scheme))
        }
    }

    static func isIPAddress(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return inet_pton(AF_INET, bare, &ipv4) == 1 || inet_pton(AF_INET6, bare, &ipv6) == 1
    }
}
