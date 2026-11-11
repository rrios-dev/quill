import Foundation
import Network

/// Waits for the one browser redirect of an OAuth sign-in on `127.0.0.1`, answers it with
/// a short page, and hands back the callback URL. Bound to the loopback address only, so
/// nothing else on the network can reach it, and closed after the first callback.
public final class LoopbackCallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let path: String
    private let page: String
    private let queue = DispatchQueue(label: "quill.loopback-callback")
    private var continuation: CheckedContinuation<URL, any Error>?
    private var ready: CheckedContinuation<UInt16, any Error>?
    private var finished = false

    /// The port actually bound: `preferred` when free, another one otherwise.
    public private(set) var port: UInt16 = 0

    /// - Parameters:
    ///   - page: the HTML the browser shows once the callback arrived, in the user's language.
    public init(preferred: UInt16, path: String, page: String) throws {
        self.path = path
        self.page = page
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: preferred) ?? .any)
        parameters.allowLocalEndpointReuse = true
        if let bound = try? NWListener(using: parameters) {
            listener = bound
        } else {
            let any = NWParameters.tcp
            any.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: any)
        }
    }

    /// Starts listening and returns the bound port, before the browser is opened.
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, any Error>) in
            queue.async { [self] in
                self.ready = ready
                listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
                listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
                listener.start(queue: queue)
            }
        }
    }

    /// Runs on `queue`.
    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener.port?.rawValue ?? 0
            ready?.resume(returning: port)
            ready = nil
        case .failed(let error):
            ready?.resume(throwing: error)
            ready = nil
        default:
            break
        }
    }

    /// The callback URL, once the browser comes back. Cancelling the task stops the server.
    public func callback() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if self.finished {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        self.continuation = continuation
                    }
                }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    public func stop() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            // "GET /auth/callback?code=…&state=… HTTP/1.1"
            let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init)
            guard let target, target.hasPrefix(path), let url = URL(string: "http://127.0.0.1:\(port)\(target)") else {
                respond(connection, status: "404 Not Found", body: "")
                return
            }
            respond(connection, status: "200 OK", body: page)
            finish(.success(url))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<URL, any Error>) {
        guard !finished else { return }
        finished = true
        listener.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }
}
