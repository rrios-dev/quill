import Foundation

@testable import ModelKit

/// An `HTTPTransport` that answers from a script and records every request,
/// so tests can assert both what was sent and how the answer is interpreted.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    enum Reply: Sendable {
        /// 200 with these body lines (an SSE stream, or a JSON document split on newlines).
        case lines([String])
        /// Non-2xx with a body and optional headers.
        case status(Int, body: String, headers: [String: String] = [:])
        /// Accepts the request and never sends anything — for cancellation and timeouts.
        case hang
    }

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let reply: @Sendable (URLRequest) -> Reply

    init(_ reply: @escaping @Sendable (URLRequest) -> Reply) {
        self.reply = reply
    }

    convenience init(_ fixed: Reply) {
        self.init { _ in fixed }
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        switch reply(request) {
        case .lines(let lines):
            return (Data(lines.joined(separator: "\n").utf8), response(request, 200, [:]))
        case .status(let code, let body, let headers):
            return (Data(body.utf8), response(request, code, headers))
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
    }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
        record(request)
        switch reply(request) {
        case .lines(let lines):
            return (response(request, 200, [:]), Self.stream(lines))
        case .status(let code, let body, let headers):
            return (response(request, code, headers), Self.stream(body.components(separatedBy: "\n")))
        case .hang:
            let stream = AsyncThrowingStream<String, any Error> { continuation in
                let task = Task {
                    try? await Task.sleep(for: .seconds(3600))
                    continuation.finish(throwing: CancellationError())
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return (response(request, 200, [:]), stream)
        }
    }

    private func record(_ request: URLRequest) {
        lock.withLock { recorded.append(request) }
    }

    private func response(_ request: URLRequest, _ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private static func stream(_ lines: [String]) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

/// Builds the SSE body a Chat Completions server streams for `text`, split
/// into one chunk per word, with a keep-alive comment and a usage chunk. The
/// last word's chunk carries `finishReason` (none when nil).
func sseStream(_ text: String, model: String = "served-model", usage: (Int, Int) = (12, 5),
               finishReason: String? = "stop") -> [String] {
    var lines = [": keep-alive"]
    let words = text.split(separator: " ", omittingEmptySubsequences: false)
    for (index, word) in words.enumerated() {
        let piece = index == 0 ? String(word) : " " + word
        let escaped = piece.replacingOccurrences(of: "\"", with: "\\\"")
        let finish = index == words.count - 1 ? finishReason.map { #","finish_reason":"\#($0)""# } ?? "" : ""
        lines.append(#"data: {"model":"\#(model)","choices":[{"delta":{"content":"\#(escaped)"}\#(finish)}]}"#)
        lines.append("")
    }
    lines.append(#"data: {"model":"\#(model)","choices":[],"usage":{"prompt_tokens":\#(usage.0),"completion_tokens":\#(usage.1)}}"#)
    lines.append("data: [DONE]")
    return lines
}

extension URLRequest {
    var jsonBody: [String: Any] {
        guard let httpBody, let object = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any] else { return [:] }
        return object
    }
}

/// Collects a stream, returning the deltas and the result — or the `ProviderError`.
func collect(_ stream: AsyncThrowingStream<GenerationEvent, any Error>) async -> (deltas: [String], result: GenerationResult?, error: ProviderError?) {
    var deltas: [String] = []
    var result: GenerationResult?
    do {
        for try await event in stream {
            switch event {
            case .delta(let text): deltas.append(text)
            case .completed(let value): result = value
            }
        }
        return (deltas, result, nil)
    } catch let error as ProviderError {
        return (deltas, result, error)
    } catch {
        return (deltas, result, ProviderError(.server, "Non-ProviderError escaped the contract: \(error)"))
    }
}
