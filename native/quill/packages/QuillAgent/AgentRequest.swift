import Foundation
import MCPKit

/// What `quill-mcp` asks the running app to do: the work that needs the user's model
/// credentials, which only the app holds (DESIGN §3.4).
public enum AgentRequest: Codable, Equatable, Sendable {
    /// Synthesise a meeting with a focus (nil: the default one in Settings).
    case synthesize(meetingID: UUID, focusID: String?)
    /// Rewrite a text with a profile, found by id or name.
    case rewrite(text: String, profile: String)

    /// The app's socket, inside its data directory.
    public static func socketPath(dataDirectory: URL) -> String {
        LocalChannel.path(named: "agent", in: dataDirectory)
    }

    /// Sends the request to the running app.
    public func send(dataDirectory: URL) async throws -> AgentReply {
        let reply = try await LocalChannel.send(try JSONEncoder().encode(self), to: Self.socketPath(dataDirectory: dataDirectory))
        return try JSONDecoder().decode(AgentReply.self, from: reply)
    }
}

/// The app's answer: the text, or why not.
public struct AgentReply: Codable, Equatable, Sendable {
    public var text: String?
    public var error: String?
    /// Small facts about the result, shown to the agent (focus, model, profile…).
    public var details: [String: String]

    public init(text: String? = nil, error: String? = nil, details: [String: String] = [:]) {
        self.text = text
        self.error = error
        self.details = details
    }

    public static func failure(_ message: String) -> AgentReply { AgentReply(error: message) }
}
