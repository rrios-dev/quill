import Foundation
import MCPKit

/// What `quill-mcp` asks the running app to do: the work that needs the user's model
/// credentials, which only the app holds (DESIGN §3.4).
public enum AgentRequest: Codable, Equatable, Sendable {
    /// Synthesise a meeting with a focus (nil: the default one in Settings).
    case synthesize(meetingID: UUID, focusID: String?)
    /// Rewrite a text with a profile, found by id or name.
    case rewrite(text: String, profile: String)
    /// The apps that could hold a meeting now, and what Quill is doing.
    case meetingApps
    /// Start transcribing an app (nil: the one in a call), optionally in a language, and
    /// stop on its own when the call ends.
    case startListening(appID: String?, language: String?, stopWhenCallEnds: Bool)
    /// What Quill is transcribing, with the last `lines` lines heard.
    case listeningStatus(lines: Int)
    /// Stop transcribing and save the meeting.
    case stopListening
    /// Wait until the meeting being transcribed ends and is saved, up to `seconds`.
    case waitForMeeting(seconds: Int)

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
