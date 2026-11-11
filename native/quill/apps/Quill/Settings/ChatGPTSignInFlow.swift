import AppKit
import ModelKit
import QuillSupport

/// Sign in with ChatGPT from Settings (quill J-23): a loopback listener on 127.0.0.1, the
/// system browser for the sign-in itself, and the validated account saved in the Keychain.
/// Quill never sees the password; the browser talks to OpenAI directly.
@MainActor
final class ChatGPTSignInFlow {
    enum Outcome: Equatable {
        case signedIn(email: String?)
        /// Signed in, but the user did not allow using their plan.
        case planNotAllowed
        case declined
        case cancelled
        case failed(String)
    }

    /// How long the browser has to come back before the attempt is dropped.
    static let browserTimeout: Duration = .seconds(300)

    private let store: ChatGPTAccountStore
    private let signIn: ChatGPTSignIn
    private var server: LoopbackCallbackServer?

    init(credentials: any CredentialStore, transport: any HTTPTransport = URLSessionTransport()) {
        store = ChatGPTAccountStore(credentials: credentials)
        signIn = ChatGPTSignIn(transport: transport, appName: QuillSupport.productName)
    }

    func run() async -> Outcome {
        do {
            let hostID = try store.hostID()
            let server = try LoopbackCallbackServer(preferred: ChatGPTPlan.preferredPort, path: ChatGPTPlan.callbackPath,
                                                    page: Self.page)
            self.server = server
            defer { server.stop(); self.server = nil }
            let port = try await server.start()
            // A saved registration is renewed with its own client; a first sign-in registers.
            let previous = store.load()
            let (url, pending) = signIn.begin(hostID: hostID, port: port, account: previous)
            NSWorkspace.shared.open(url)
            let callback = try await Self.withTimeout(Self.browserTimeout) { try await server.callback() }
            let account = try await signIn.finish(callback: callback, pending: pending, previous: previous)
            try store.save(account)
            return .signedIn(email: account.email)
        } catch let failure as ChatGPTSignIn.Failure {
            switch failure {
            case .declined: return .declined
            case .planNotAllowed(let account):
                // Kept, so allowing the plan later reuses this registration.
                try? store.save(account)
                return .planNotAllowed
            default: return .failed(String(describing: failure))
            }
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(String(describing: error))
        }
    }

    func cancel() {
        server?.stop()
    }

    /// Ends the session at OpenAI and forgets the account on this Mac. Returns whether
    /// OpenAI confirmed it; the local tokens go either way.
    func signOut() async -> Bool {
        guard let account = store.load() else { return true }
        let confirmed = await signIn.revoke(account)
        try? store.clear()
        return confirmed
    }

    var account: ChatGPTAccount? { store.load() }

    /// What the browser shows once it comes back.
    static var page: String {
        let title = PickerCopy.string("chatgpt.callback.title")
        let body = PickerCopy.string("chatgpt.callback.body \(QuillSupport.productName)")
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
        <style>body{font:15px -apple-system,system-ui;margin:20vh auto;max-width:28em;text-align:center;color:#1d1d1f}
        @media (prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}}</style></head>
        <body><h1 style="font-weight:600;font-size:22px">\(title)</h1><p>\(body)</p></body></html>
        """
    }

    private static func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw CancellationError()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
