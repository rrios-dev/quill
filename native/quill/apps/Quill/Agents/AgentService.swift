import Foundation
import MCPKit
import ModelKit
import Observation
import QuillAgent
import QuillSupport
import RewriteKit

/// Quill's side of agent access (docs/initiatives/mac-apps-mcp/DESIGN.md): the switch,
/// the access log, the socket where `quill-mcp` hands over what needs the app, and
/// registering `quill-mcp` with Claude Code and Codex.
@MainActor
@Observable
final class AgentService {
    private(set) var access: AgentAccess
    private(set) var recent: [AccessLog.Entry] = []
    /// What the last Connect or Disconnect said, per client.
    private(set) var clientStatus: [AgentClient: String] = [:]
    private(set) var working: AgentClient?

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private weak var meetings: MeetingsCoordinator?
    @ObservationIgnored private var listener: LocalChannel.Listener?
    @ObservationIgnored private let log: AccessLog
    @ObservationIgnored private let logger = QuillLog(category: "agents")

    init(environment: AppEnvironment, meetings: MeetingsCoordinator?) {
        self.environment = environment
        self.meetings = meetings
        access = AgentAccess.load(from: environment.dataDirectory)
        log = AccessLog(directory: environment.dataDirectory)
        refreshLog()
        updateListener()
    }

    var dataDirectory: URL { environment.dataDirectory }

    /// `quill-mcp` next to the app's own executable.
    static var serverPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/quill-mcp").path
    }

    func setEnabled(_ enabled: Bool) {
        access.enabled = enabled
        do {
            try access.save(to: environment.dataDirectory)
        } catch {
            logger.error("could not save agent access: \(error)")
        }
        updateListener()
    }

    func refreshLog() { recent = log.recent(12) }

    func clearLog() {
        log.clear()
        refreshLog()
    }

    func stop() {
        listener?.stop()
        listener = nil
    }

    /// The socket listens only while access is on.
    private func updateListener() {
        guard access.enabled else {
            stop()
            return
        }
        guard listener == nil else { return }
        let path = AgentRequest.socketPath(dataDirectory: environment.dataDirectory)
        do {
            listener = try LocalChannel.Listener(path: path) { [weak self] data in
                let reply: AgentReply
                if let request = try? JSONDecoder().decode(AgentRequest.self, from: data) {
                    reply = await self?.handle(request) ?? .failure("Quill is quitting.")
                } else {
                    reply = .failure("Quill did not understand the request; update Quill and quill-mcp together.")
                }
                return (try? JSONEncoder().encode(reply)) ?? Data()
            }
        } catch {
            logger.error("agent socket unavailable: \(error)")
        }
    }

    private func handle(_ request: AgentRequest) async -> AgentReply {
        // The switch is checked here too: the server checks it, but the app owns it.
        guard access.enabled else { return .failure(QuillTools.refusal) }
        defer { refreshLog() }
        switch request {
        case .synthesize(let meetingID, let focusID):
            guard let meetings else { return .failure("Meetings are unavailable in this Quill.") }
            return await meetings.synthesizeForAgent(meetingID: meetingID, focusID: focusID)
        case .rewrite(let text, let profile):
            return await rewrite(text, with: profile)
        }
    }

    // MARK: Rewriting

    /// The profile's text rewrite, as Try it runs it (`ProfilesPaneModel.tryIt`): its
    /// model, the user's consent for a hosted recipient, no streaming.
    private func rewrite(_ text: String, with query: String) async -> AgentReply {
        let profiles = (try? environment.profiles.all().profiles) ?? []
        let folded = query.trimmingCharacters(in: .whitespaces)
        guard let profile = profiles.first(where: { $0.id.uuidString.caseInsensitiveCompare(folded) == .orderedSame })
            ?? profiles.first(where: { $0.name.compare(folded, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame })
        else {
            return .failure("No profile “\(query)”. Quill has: \(profiles.map(\.name).sorted().joined(separator: ", ")).")
        }
        let settings = (try? environment.settings.settings()) ?? QuillSettings()
        guard let model = profile.model ?? settings.globalModel,
              let provider = environment.registry.current[model.provider] else {
            return .failure("“\(profile.name)” has no model. The user can choose one in Quill › Settings › Providers.")
        }
        let remote = ConsentRule.isRemote(provider.descriptor, treatLoopbackAsRemote: DebugHooks.treatsLoopbackAsRemote)
        if ConsentRule.notice(for: provider.descriptor, profile: profile, settings: settings, remote: remote) != nil {
            return .failure("""
                The first time “\(profile.name)” sends text to \(provider.descriptor.displayName), Quill asks the user. \
                Ask them to rewrite something with that profile in Quill once and accept; after that agents can use it.
                """)
        }
        let catalog = LiveModelCatalog(registry: environment.registry, listCache: environment.modelCache)
        let context: Int? = if let maximum = provider.descriptor.traits.maxContextTokens {
            maximum
        } else {
            await catalog.descriptor(for: model)?.contextTokens
        }
        guard let engine = try? GenerationEngine() else { return .failure("Quill could not start its rewriting engine.") }
        let request = GenerationEngine.Request(
            profile: profile, input: text, model: model, contextTokens: context, runsOnDevice: !remote,
            formatting: .plain, streams: false)
        let outcome = await engine.run(request, provider: provider)
        let details = ["profile": profile.name, "model": "\(model.provider.rawValue):\(model.model.rawValue)"]
        switch outcome.state {
        case .ready(let rewritten, _):
            return AgentReply(text: rewritten, details: details)
        case .noChanges:
            return AgentReply(text: text, details: details.merging(["note": "no changes needed"]) { $1 })
        case .truncated(let partial):
            return AgentReply(text: partial, details: details.merging(["note": "truncated by the model"]) { $1 })
        case .refused:
            return .failure("The model refused to rewrite this text.")
        case .tooLong:
            return .failure("The text is too long for “\(profile.name)”'s model.")
        case .failed(let code, _):
            return .failure("The model failed (\(code)).")
        case .idle, .generating, .cancelled:
            return .failure("The rewrite was cancelled.")
        }
    }

    // MARK: Clients

    /// Registers `quill-mcp` with a client through its own CLI, run in a login shell so
    /// the user's PATH applies (a GUI app does not inherit it). A previous registration
    /// is removed first, so connecting again after moving Quill fixes the path.
    /// The name agents see this server under.
    static let server = "quill"

    func connect(_ client: AgentClient) async {
        working = client
        defer { working = nil }
        clientStatus[client] = Self.status(await client.connect(server: Self.server, path: Self.serverPath), connected: true, client: client)
    }

    func disconnect(_ client: AgentClient) async {
        working = client
        defer { working = nil }
        clientStatus[client] = Self.status(await client.disconnect(server: Self.server), connected: false, client: client)
    }

    private static func status(_ outcome: AgentClient.Outcome, connected: Bool, client: AgentClient) -> String {
        switch outcome {
        case .done:
            connected
                ? String(localized: "agents.connected \(client.name)", bundle: .localized)
                : String(localized: "agents.disconnected \(client.name)", bundle: .localized)
        case .notInstalled:
            String(localized: "agents.notInstalled \(client.name)", bundle: .localized)
        case .failed(let line):
            String(localized: "agents.failed \(line)", bundle: .localized)
        }
    }
}
