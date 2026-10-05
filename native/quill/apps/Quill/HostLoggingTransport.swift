import Foundation
import ModelKit
import QuillSupport

/// `QUILL_LOG_HOSTS` (ARCHITECTURE §3.6, §6; PLAN P5-T5): logs the host of every request
/// the app's providers make — scheme, host and port, never the path, the headers or the
/// body — so the privacy pass can confirm Quill talks only to the provider a profile
/// resolves to, and only when asked. Debug builds only: in release the hook reads unset
/// and the app uses the plain transport.
struct HostLoggingTransport: HTTPTransport {
    let base: any HTTPTransport
    private let log = QuillLog(category: "hosts")

    init(base: any HTTPTransport = URLSessionTransport()) { self.base = base }

    /// The transport the app's providers use.
    static func live() -> any HTTPTransport {
        DebugHooks.logsHosts ? HostLoggingTransport() : URLSessionTransport()
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        return try await base.data(for: request)
    }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
        record(request)
        return try await base.lines(for: request)
    }

    static func host(of request: URLRequest) -> String {
        guard let url = request.url, let host = url.host() else { return "-" }
        return "\(url.scheme ?? "-")://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    private func record(_ request: URLRequest) {
        log.info("QUILL-HOST \(Self.host(of: request))")
    }
}
