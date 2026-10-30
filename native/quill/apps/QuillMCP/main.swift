import Foundation
import MCPKit
import MeetingKit
import QuillAgent
import QuillSupport

// quill-mcp: Quill's MCP server (docs/initiatives/mac-apps-mcp/DESIGN.md). It lives in
// Quill.app/Contents/MacOS, so Bundle.main is Quill's bundle: the same identifier, the
// same data directory, the same string tables. An agent launches it over stdio:
//
//   claude mcp add --scope user quill -- /Applications/Quill.app/Contents/MacOS/quill-mcp
//
// stdout carries only the protocol.

let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.rrios.quill"
var dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent(bundleIdentifier, isDirectory: true)
#if DEBUG
// The app's own debug hook, honoured only by debug builds as in the app.
if let override = ProcessInfo.processInfo.environment["QUILL_DATA_DIR"], !override.isEmpty {
    dataDirectory = URL(fileURLWithPath: override, isDirectory: true)
}
#endif
let directory = dataDirectory

let strings = ResourceBundle.resolve("Quill_Quill", fallback: .main)
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
let log = AccessLog(directory: directory)
let tools = QuillTools(dataDirectory: directory, builtInText: MeetingStore.BuiltInText(strings: strings),
                       replaced: ExecutableIdentity.replacedSinceLaunch())

let server = Server(
    info: Server.Info(name: "quill", title: "Quill", version: version, instructions: QuillTools.instructions),
    tools: tools.all,
    gate: { AgentAccess.load(from: directory).enabled ? nil : QuillTools.refusal },
    onCall: log.recorder()
)
await server.run()
