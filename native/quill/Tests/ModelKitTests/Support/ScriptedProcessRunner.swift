import Foundation

@testable import ModelKit

/// A `ProcessRunner` that answers from a script and records every invocation, so tests
/// can assert what would have been launched and how the output is read.
final class ScriptedProcessRunner: ProcessRunner, @unchecked Sendable {
    enum Reply: Sendable {
        /// Prints these lines, then exits with `status` (non-zero throws `ProcessFailure`).
        case lines([String], status: Int32 = 0)
        /// The executable could not be launched.
        case launchFailure
        /// Starts and never prints anything — for cancellation and timeouts.
        case hang
    }

    private let lock = NSLock()
    private var recorded: [ProcessInvocation] = []
    private var terminated = false
    private let reply: Reply

    init(_ reply: Reply) {
        self.reply = reply
    }

    var invocations: [ProcessInvocation] { lock.withLock { recorded } }
    /// Whether the consumer stopped listening before the process finished.
    var wasTerminated: Bool { lock.withLock { terminated } }

    func lines(_ invocation: ProcessInvocation) -> AsyncThrowingStream<String, any Error> {
        lock.withLock { recorded.append(invocation) }
        let reply = reply
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch reply {
                case .lines(let lines, let status):
                    for line in lines { continuation.yield(line) }
                    if status == 0 {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: ProcessFailure(status: status, standardError: "boom"))
                    }
                case .launchFailure:
                    continuation.finish(throwing: ProcessFailure(status: nil, standardError: "no such file"))
                case .hang:
                    try? await Task.sleep(for: .seconds(3600))
                    continuation.finish()
                }
            }
            continuation.onTermination = { [weak self] reason in
                task.cancel()
                if case .cancelled = reason { self?.lock.withLock { self?.terminated = true } }
            }
        }
    }
}

/// Claude Code's `stream-json` output for a successful call, shaped like a real run
/// (2.1.316, 2026-11-11): init, thinking, text deltas, the plan's rate-limit state, result.
func claudeCodeStream(_ pieces: [String], model: String = "claude-haiku-5-5", apiKeySource: String = "none",
                      stopReason: String = "end_turn", usage: (input: Int, created: Int, read: Int, output: Int) = (2, 627, 0, 12),
                      limit: (status: String, resetsAt: Int) = ("allowed", 1_794_978_000)) -> [String] {
    let text = pieces.joined()
    var lines = [
        #"{"type":"system","subtype":"init","cwd":"/tmp","model":"\#(model)","apiKeySource":"\#(apiKeySource)","claude_code_version":"2.1.316"}"#,
        #"{"type":"stream_event","event":{"type":"message_start"}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":""}}}"#,
    ]
    for piece in pieces {
        lines.append(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":\#(json(piece))}}}"#)
    }
    lines += [
        #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"\#(stopReason)"}}}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"\#(limit.status)","resetsAt":\#(limit.resetsAt),"rateLimitType":"seven_day"}}"#,
        #"{"type":"result","subtype":"success","is_error":false,"result":\#(json(text)),"stop_reason":"\#(stopReason)","api_error_status":null,"usage":{"input_tokens":\#(usage.input),"cache_creation_input_tokens":\#(usage.created),"cache_read_input_tokens":\#(usage.read),"output_tokens":\#(usage.output)},"modelUsage":{"\#(model)":{"inputTokens":2}}}"#,
    ]
    return lines
}

/// A failed call: Claude Code still prints a result line, with `is_error` and, when the
/// API answered, its status.
func claudeCodeFailure(_ message: String, status: Int? = nil, limit: String? = nil) -> [String] {
    var lines = [#"{"type":"system","subtype":"init","model":"claude-haiku-5-5","apiKeySource":"none"}"#]
    if let limit {
        lines.append(#"{"type":"rate_limit_event","rate_limit_info":{"status":"\#(limit)","resetsAt":\#(Int(Date().timeIntervalSince1970) + 600)}}"#)
    }
    lines.append(#"{"type":"result","subtype":"success","is_error":true,"result":\#(json(message)),"stop_reason":"stop_sequence","api_error_status":\#(status.map(String.init) ?? "null")}"#)
    return lines
}

private func json(_ text: String) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), as: UTF8.self)
}
