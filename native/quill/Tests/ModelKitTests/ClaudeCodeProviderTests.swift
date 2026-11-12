import Foundation
import Testing

@testable import ModelKit

/// The provider contract (ProviderContractTests' scenarios) against Claude Code's
/// output, plus what this provider promises on top: the plan is used, never an API key,
/// and the text reaches nothing that can act.
@Suite("Claude Code provider")
struct ClaudeCodeProviderTests {
    static let executable = URL(filePath: "/Users/someone/.local/bin/claude")

    private func provider(_ runner: ScriptedProcessRunner, installed: Bool = true,
                          environment: [String: String] = ["PATH": "/usr/bin:/bin", "HOME": "/Users/someone"],
                          effort: String? = nil) -> ClaudeCodeProvider {
        ClaudeCodeProvider(runner: runner, locate: { installed ? Self.executable : nil }, environment: environment,
                           workingDirectory: FileManager.default.temporaryDirectory.appending(path: "quill-claude-code-tests"),
                           effort: effort)
    }

    private func request(timeout: Duration = .seconds(5), examples: [GenerationRequest.Example] = [],
                         maxOutputTokens: Int? = nil) -> GenerationRequest {
        GenerationRequest(model: "haiku", instructions: "Fix spelling.", input: "helo hw r u", examples: examples,
                          options: GenerationOptions(maxOutputTokens: maxOutputTokens, timeout: timeout))
    }

    // MARK: Contract

    @Test("streams deltas and finishes with exactly one result")
    func streamsAndCompletes() async {
        let runner = ScriptedProcessRunner(.lines(claudeCodeStream(["Hello, ", "how are you? 👋"])))
        let outcome = await collect(provider(runner).stream(request()))

        #expect(outcome.error == nil)
        #expect(outcome.deltas == ["Hello, ", "how are you? 👋"])
        #expect(outcome.result?.text == "Hello, how are you? 👋")
        #expect(outcome.result?.provider == "claude-code")
        #expect(outcome.result?.model == "claude-haiku-5-5", "the answering model, not the alias")
        #expect(outcome.result?.usage == TokenUsage(inputTokens: 629, outputTokens: 12), "cached input counts as input")
        #expect(outcome.result?.finishReason == .stop)
    }

    @Test("a result with no deltas is still streamed once")
    func resultWithoutDeltas() async {
        var lines = claudeCodeStream(["Hello"])
        lines.removeAll { $0.contains("text_delta") }
        let outcome = await collect(provider(ScriptedProcessRunner(.lines(lines))).stream(request()))

        #expect(outcome.deltas == ["Hello"])
        #expect(outcome.result?.text == "Hello")
    }

    @Test("an answer cut by the output limit reports .length")
    func cutOff() async {
        let runner = ScriptedProcessRunner(.lines(claudeCodeStream(["Hello"], stopReason: "max_tokens")))
        #expect(await collect(provider(runner).stream(request())).result?.finishReason == .length)
    }

    @Test("a tool that is not installed is reported before anything is launched")
    func notInstalled() async {
        let runner = ScriptedProcessRunner(.lines(claudeCodeStream(["unused"])))
        let provider = provider(runner, installed: false)

        #expect(await provider.availability() == .unavailable(.appNotInstalled))
        let outcome = await collect(provider.stream(request()))
        #expect(outcome.error?.code == .unavailable(.appNotInstalled))
        #expect(runner.invocations.isEmpty)
    }

    @Test("a signed-out tool maps to .notSignedIn")
    func signedOut() async {
        let runner = ScriptedProcessRunner(.lines(claudeCodeFailure("Not logged in · Please run /login"), status: 1))
        let outcome = await collect(provider(runner).stream(request()))

        #expect(outcome.error?.code == .unavailable(.notSignedIn))
        #expect(outcome.error?.isRetriable == false)
    }

    @Test("a revoked session (401) maps to .notSignedIn, not to a key error")
    func revokedSession() async {
        let runner = ScriptedProcessRunner(.lines(claudeCodeFailure("OAuth access token has been revoked", status: 401), status: 1))
        let outcome = await collect(provider(runner).stream(request()))

        #expect(outcome.error?.code == .unavailable(.notSignedIn))
        #expect(outcome.error?.status == 401)
    }

    @Test("an unknown model maps to .invalidRequest")
    func unknownModel() async {
        let message = "There's an issue with the selected model (claude-nonexistent-9)."
        let runner = ScriptedProcessRunner(.lines(claudeCodeFailure(message, status: 404), status: 1))
        #expect(await collect(provider(runner).stream(request())).error?.code == .invalidRequest)
    }

    @Test("a plan at its limit maps to .rateLimited with the time it resets")
    func planLimit() async throws {
        let runner = ScriptedProcessRunner(.lines(claudeCodeFailure("Claude AI usage limit reached", limit: "rejected"), status: 1))
        let error = try #require(await collect(provider(runner).stream(request())).error)

        guard case .rateLimited(let wait) = error.code else { Issue.record("got \(error.code)"); return }
        let seconds = try #require(wait).components.seconds
        #expect((590...600).contains(seconds))
        #expect(error.isRetriable)
    }

    @Test("a launch failure maps to .appNotInstalled; a crash without a result to .server")
    func processFailures() async {
        #expect(await collect(provider(ScriptedProcessRunner(.launchFailure)).stream(request())).error?.code
            == .unavailable(.appNotInstalled))
        let crashed = ScriptedProcessRunner(.lines([#"{"type":"system","subtype":"init","apiKeySource":"none"}"#], status: 2))
        #expect(await collect(provider(crashed).stream(request())).error?.code == .server)
    }

    @Test("output that ends without a result is malformed")
    func noResult() async {
        let runner = ScriptedProcessRunner(.lines([#"{"type":"system","subtype":"init","apiKeySource":"none"}"#, "not json"]))
        #expect(await collect(provider(runner).stream(request())).error?.code == .malformedResponse)
    }

    @Test("cancelling a stream ends it quietly and terminates the process")
    func streamCancellation() async {
        let runner = ScriptedProcessRunner(.hang)
        let provider = provider(runner)
        let consumer = Task { await collect(provider.stream(request(timeout: .seconds(30)))) }
        try? await Task.sleep(for: .milliseconds(50))
        consumer.cancel()

        let outcome = await consumer.value
        #expect(outcome.result == nil)
        #expect(outcome.error == nil || outcome.error?.code == .cancelled, "cancellation must not look like a failure")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(runner.wasTerminated)
    }

    @Test("cancelling generate() throws .cancelled")
    func generateCancellation() async {
        let provider = provider(ScriptedProcessRunner(.hang))
        let consumer = Task { () -> ProviderError? in
            do {
                _ = try await provider.generate(request(timeout: .seconds(30)))
                return nil
            } catch let error as ProviderError {
                return error
            } catch {
                return ProviderError(.server, "foreign error escaped: \(type(of: error))")
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        consumer.cancel()

        #expect(await consumer.value?.code == .cancelled)
    }

    @Test("a generation past its deadline fails with .timeout")
    func timeout() async {
        let outcome = await collect(provider(ScriptedProcessRunner(.hang)).stream(request(timeout: .milliseconds(80))))
        #expect(outcome.error?.code == .timeout)
    }

    // MARK: What this provider promises

    @Test("a call that would bill an API key is refused, whatever the tool answers")
    func refusesAPIKeyBilling() async {
        let runner = ScriptedProcessRunner(.lines(claudeCodeStream(["Hello"], apiKeySource: "ANTHROPIC_API_KEY")))
        let outcome = await collect(provider(runner).stream(request()))

        #expect(outcome.result == nil)
        #expect(outcome.deltas.isEmpty)
        #expect(outcome.error?.code == .unavailable(.notSignedIn))
    }

    @Test("the child gets no API key or other cloud, and runs quiet")
    func environment() throws {
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/Users/someone", "ANTHROPIC_API_KEY": "sk-ant-x",
                    "ANTHROPIC_AUTH_TOKEN": "t", "ANTHROPIC_BASE_URL": "https://proxy", "CLAUDE_CODE_USE_BEDROCK": "1",
                    "CLAUDE_CODE_OAUTH_TOKEN": "plan-token"]
        let env = ClaudeCodeProvider.childEnvironment(base, executable: Self.executable, request: request(maxOutputTokens: 900))

        for key in ClaudeCodeProvider.billingOverrides { #expect(env[key] == nil, "\(key) must not reach the child") }
        #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == "plan-token", "the user's own plan token is theirs to use")
        #expect(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
        #expect(env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] == "900")
        #expect(env["HOME"] == "/Users/someone")
        let path = try #require(env["PATH"]).split(separator: ":").map(String.init)
        #expect(path.first == "/Users/someone/.local/bin", "the tool's own folder comes first")
        #expect(path.contains("/opt/homebrew/bin"))
    }

    @Test("one turn with no tools, settings, hooks or MCP; the text goes on standard input")
    func invocationShape() async throws {
        let runner = ScriptedProcessRunner(.lines(claudeCodeStream(["ok"])))
        _ = await collect(provider(runner, effort: "low").stream(request()))

        let sent = try #require(runner.invocations.first)
        let args = sent.arguments
        #expect(sent.executable == Self.executable)
        #expect(args.first == "-p")
        #expect(!args.contains("--bare"), "bare mode never reads the plan's session")
        #expect(value(after: "--tools", in: args) == "")
        #expect(value(after: "--setting-sources", in: args) == "")
        #expect(value(after: "--settings", in: args) == #"{"disableAllHooks":true}"#)
        #expect(args.contains("--strict-mcp-config"))
        #expect(args.contains("--no-session-persistence"))
        #expect(value(after: "--output-format", in: args) == "stream-json")
        #expect(value(after: "--model", in: args) == "haiku")
        #expect(value(after: "--system-prompt", in: args)?.hasPrefix("Fix spelling.\n\n") == true)
        #expect(value(after: "--effort", in: args) == "low")
        #expect(!args.contains("helo hw r u"), "the user's text is never an argument")
        #expect(String(decoding: sent.standardInput, as: UTF8.self) == "helo hw r u")
    }

    @Test("worked examples go to the system prompt, the input stays on standard input")
    func examples() {
        let prompt = ClaudeCodeProvider.systemPrompt(for: request(examples: [.init(input: "thx", output: "Thanks")]))
        #expect(prompt.hasPrefix("Fix spelling.\n\nExamples"))
        #expect(prompt.hasSuffix(ClaudeCodeProvider.plainTextNote + " " + ClaudeCodeProvider.lineBreakRule(for: "helo hw r u")))
        #expect(prompt.contains("<input>\nthx\n</input>\n<output>\nThanks\n</output>"))
        #expect(!prompt.contains("helo hw r u"))
    }

    @Test("an answer that does not replace the selection gets no plain-text rules")
    func synthesisPrompt() {
        var synthesis = request()
        synthesis.options.replacesSelection = false
        #expect(ClaudeCodeProvider.systemPrompt(for: synthesis) == "Fix spelling.")
    }

    @Test("the line-break rule names the input's own count")
    func lineBreaks() {
        #expect(ClaudeCodeProvider.lineBreakRule(for: "one paragraph").contains("no line breaks"))
        #expect(ClaudeCodeProvider.lineBreakRule(for: "a\nb").contains("1 line break:"))
        #expect(ClaudeCodeProvider.lineBreakRule(for: "a\n\nb\nc").contains("3 line breaks"))
    }

    @Test("the model list is Claude Code's aliases, recommended first")
    func models() async throws {
        let provider = ClaudeCodeProvider(runner: ScriptedProcessRunner(.hang), locate: { nil }, recommended: ["haiku"])
        let models = try await provider.models()
        #expect(models.map(\.id) == ["haiku", "sonnet", "opus"])
        #expect(models.allSatisfy { $0.vendor == "anthropic" })
    }

    @Test("the locator expands the home folder and keeps the first executable candidate")
    func locator() {
        let found = ClaudeCodeLocator.locate(in: ["~/.local/bin/claude", "/opt/homebrew/bin/claude"], home: "/Users/someone",
                                             isExecutable: { $0 == "/opt/homebrew/bin/claude" })
        #expect(found?.path == "/opt/homebrew/bin/claude")
        #expect(ClaudeCodeLocator.locate(in: ["~/.local/bin/claude"], home: "/Users/someone", isExecutable: { _ in false }) == nil)
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }
}
