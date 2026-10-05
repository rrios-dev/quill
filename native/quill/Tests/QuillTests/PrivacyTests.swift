import Foundation
import ModelKit
import Testing

@testable import Quill

@Suite("Privacy hooks")
struct PrivacyTests {
    final class Recorder: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { _requests } }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.withLock { _requests.append(request) }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
            lock.withLock { _requests.append(request) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    AsyncThrowingStream { $0.finish() })
        }
    }

    @Test("the host log names scheme, host and port — never the path, query or body")
    func hostOnly() {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions?key=secret")!)
        request.httpBody = Data("user text".utf8)
        #expect(HostLoggingTransport.host(of: request) == "https://openrouter.ai")
        #expect(HostLoggingTransport.host(of: URLRequest(url: URL(string: "http://127.0.0.1:8767/v1/models")!))
                == "http://127.0.0.1:8767")
    }

    @Test("requests pass through unchanged")
    func passesThrough() async throws {
        let recorder = Recorder()
        let transport = HostLoggingTransport(base: recorder)
        let request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        _ = try await transport.data(for: request)
        _ = try await transport.lines(for: request)
        #expect(recorder.requests.map(\.url) == [request.url, request.url])
    }
}
