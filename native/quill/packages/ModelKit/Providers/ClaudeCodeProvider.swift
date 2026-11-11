import Foundation

/// A provider that runs the user's own Claude Code, so generations draw on the Claude
/// plan they already pay for instead of an API key (quill J-23,
/// `docs/studies/quill-claude-subscription/`).
///
/// What Anthropic's terms leave open is a user signing in to the **unmodified**
/// Claude Code binary with their own plan. So this provider never ships, patches or
/// signs in to the binary, and never reads, stores or relays a credential: it launches
/// whatever `claude` the user installed, which uses the session the user opened in it.
///
/// Each generation is one headless call with no tools, no settings, no hooks and no
/// MCP servers — the text it rewrites comes from other people and must not reach
/// anything that acts (cognee K-83bbba8e) — and with non-essential traffic off, which
/// measured 1–2 s instead of 4–6 s per short call (study E3).
public struct ClaudeCodeProvider: ModelProvider {
    public static let providerID: ProviderID = "claude-code"

    public let descriptor: ProviderDescriptor
    private let runner: any ProcessRunner
    private let locate: @Sendable () -> URL?
    private let environment: [String: String]
    private let workingDirectory: URL
    private let effort: String?
    private let recommended: Set<ModelID>

    /// - Parameters:
    ///   - locate: finds the `claude` executable; `nil` when it is not installed.
    ///   - environment: the base environment of the child, normally the app's own.
    ///     Variables that would bill an API key instead of the plan are removed.
    ///   - workingDirectory: an empty folder, so no project instructions are picked up.
    ///   - effort: Claude Code's `--effort` level; `nil` keeps its default.
    public init(runner: any ProcessRunner = FoundationProcessRunner(),
                locate: @escaping @Sendable () -> URL? = ClaudeCodeLocator.standard,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                workingDirectory: URL = FileManager.default.temporaryDirectory.appending(path: "quill-claude-code"),
                effort: String? = nil, recommended: [ModelID] = []) {
        self.descriptor = ProviderDescriptor(
            id: Self.providerID,
            displayName: "Claude Code",
            traits: ProviderTraits(execution: .remote(recipients: [.named("Anthropic")]), cost: .includedInPlan,
                                   credential: .signedInApp("Claude Code")),
            notes: [.singleRecipient, .strongModels])
        self.runner = runner
        self.locate = locate
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.effort = effort
        self.recommended = Set(recommended)
    }

    // MARK: - ModelProvider

    /// Only whether the tool is installed: checking the session would need a call, and
    /// `claude auth status` reads local state only, so it says "logged in" for a
    /// revoked session (cognee K-444e0aa3). A signed-out tool fails at call time instead.
    public func availability() async -> ProviderAvailability {
        locate() == nil ? .unavailable(.appNotInstalled) : .available
    }

    /// Claude Code's aliases, which always name the latest model of each family.
    public func models() async throws -> [ModelDescriptor] {
        let all = [("sonnet", "Claude Sonnet"), ("opus", "Claude Opus"), ("haiku", "Claude Haiku")].map { id, name in
            ModelDescriptor(id: ModelID(rawValue: id), displayName: name, contextTokens: Self.contextTokens,
                            isRecommended: recommended.contains(ModelID(rawValue: id)), vendor: "anthropic")
        }
        return all.filter(\.isRecommended) + all.filter { !$0.isRecommended }
    }

    public func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error> {
        let provider = id
        return GenerationStream.make(provider: provider, timeout: request.options.timeout) { continuation in
            guard let executable = locate() else {
                throw ProviderError(.unavailable(.appNotInstalled), "Claude Code is not installed.", provider: provider)
            }
            try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            let invocation = ProcessInvocation(
                executable: executable, arguments: arguments(for: request),
                environment: Self.childEnvironment(environment, executable: executable, request: request),
                workingDirectory: workingDirectory, standardInput: Data(request.input.utf8))

            let started = ContinuousClock.now
            var parser = EventParser(provider: provider, requested: request.model)
            do {
                for try await line in runner.lines(invocation) {
                    try Task.checkCancellation()
                    switch try parser.consume(line) {
                    case .delta(let text): continuation.yield(.delta(text))
                    case .finished(var result):
                        if !parser.streamedText, !result.text.isEmpty { continuation.yield(.delta(result.text)) }
                        result.latency = started.elapsed
                        continuation.yield(.completed(result))
                        return
                    case nil: continue
                    }
                }
            } catch let failure as ProcessFailure {
                throw Self.map(failure, provider: provider)
            }
            throw ProviderError(.malformedResponse, "Claude Code ended without a result.", provider: provider)
        }
    }

    // MARK: - Invocation

    /// The context Claude Code's models accept, for the pre-check; theirs is larger.
    static let contextTokens = 200_000

    func arguments(for request: GenerationRequest) -> [String] {
        var arguments = [
            "-p",
            "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--settings", #"{"disableAllHooks":true}"#,
            "--no-session-persistence",
            "--model", request.model.rawValue,
            "--system-prompt", Self.systemPrompt(for: request),
        ]
        if let effort { arguments += ["--effort", effort] }
        return arguments
    }

    /// The instructions, then the worked examples. Claude Code takes one user message,
    /// so examples cannot be turns; the input stays apart, on standard input.
    static func systemPrompt(for request: GenerationRequest) -> String {
        var prompt = request.instructions
        if !request.examples.isEmpty {
            let examples = request.examples.map {
                "<example>\n<input>\n\($0.input)\n</input>\n<output>\n\($0.output)\n</output>\n</example>"
            }
            prompt += "\n\nExamples of the expected transformation (an input, then the answer to give):\n"
                + examples.joined(separator: "\n")
        }
        // Last, nearest the text: models follow the closest, most concrete constraint.
        return prompt + "\n\n" + plainTextNote + " " + lineBreakRule(for: request.input)
    }

    /// Claude Code wraps every call in its own context, and its models lean towards
    /// Markdown and letter form: measured on the bench, Sonnet split single paragraphs,
    /// added greetings and sign-offs, numbered points, dropped hedges when shortening,
    /// and read "keep names exactly" as "leave a misspelt name alone" (study R3–R4). The
    /// note restates, for these models only, what the profiles already ask; other
    /// providers' prompts are untouched. The bench's readiness labels key on the
    /// profile's prompt hash, which does not include this note: changing it means
    /// running the gate again (J-25), or the labels describe a prompt no longer sent.
    static let plainTextNote = """
        Your answer replaces the user's selection as it is, so write it once: if you notice a \
        mistake, never add a correction or a second version — get it right before you write. \
        Write plain text: no Markdown, \
        no headings, no bullets or numbering the text does not already have, and nothing \
        before or after it — no greeting, sign-off or note. Keeping names exactly still means \
        fixing their spelling, accents and capitals (lucia → Lucía). Shortening never drops a \
        word that says how sure or how soon something is (soon, maybe, probably). In a formal \
        register, laughter (jajaja, lol) goes with the other filler, and a tú imperative keeps \
        its verb and pronouns in the usted form (reclámaselas → reclámeselas).
        """

    /// The input's line breaks as a count the answer must match: a concrete number holds
    /// where "keep the line breaks" did not.
    static func lineBreakRule(for input: String) -> String {
        let breaks = input.filter { $0 == "\n" }.count
        return breaks == 0
            ? "The text has no line breaks: answer in one single paragraph, with no line breaks at all."
            : "The text has \(breaks) line break\(breaks == 1 ? "" : "s"): keep exactly those, in the same places, and add none."
    }

    /// Variables that would make Claude Code bill an API key or another cloud instead
    /// of the user's plan. In print mode an API key wins over the signed-in session.
    static let billingOverrides: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
    ]

    static func childEnvironment(_ base: [String: String], executable: URL, request: GenerationRequest) -> [String: String] {
        var environment = base.filter { !billingOverrides.contains($0.key) }
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["DISABLE_TELEMETRY"] = "1"
        if let limit = request.options.maxOutputTokens { environment["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = String(limit) }
        // An app opened from the Finder has a minimal PATH; an npm install of the tool
        // needs `node`, which lives next to it or in Homebrew.
        let path = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                    environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }

    static func map(_ failure: ProcessFailure, provider: ProviderID) -> ProviderError {
        guard failure.status != nil else {
            return ProviderError(.unavailable(.appNotInstalled), "Claude Code could not be launched: \(failure.standardError)",
                                 provider: provider)
        }
        return ProviderError(.server, "Claude Code exited with status \(failure.status ?? 0): \(failure.standardError.suffix(300))",
                             provider: provider)
    }
}

// MARK: - Output

extension ClaudeCodeProvider {
    /// Reads Claude Code's `stream-json` lines: text deltas, the plan's rate-limit state
    /// and the final result.
    struct EventParser {
        enum Output: Equatable {
            case delta(String)
            case finished(GenerationResult)
        }

        let provider: ProviderID
        let requested: ModelID
        private(set) var streamedText = false
        private var model: ModelID?
        private var stopReason: String?
        private var limitResetsAt: Date?
        private var limitRejected = false

        init(provider: ProviderID, requested: ModelID) {
            self.provider = provider
            self.requested = requested
        }

        mutating func consume(_ line: String) throws -> Output? {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(Event.self, from: data) else { return nil }
            switch event.type {
            case "system" where event.subtype == "init":
                model = event.model.map(ModelID.init(rawValue:))
                // The guarantee this provider sells: no call is billed to an API key.
                if let source = event.apiKeySource, source != "none" {
                    throw ProviderError(.unavailable(.notSignedIn),
                                        "Claude Code would bill an API key (\(source)), not the plan.", provider: provider)
                }
            case "stream_event":
                if event.event?.delta?.type == "text_delta", let text = event.event?.delta?.text, !text.isEmpty {
                    streamedText = true
                    return .delta(text)
                }
                if let reason = event.event?.delta?.stopReason { stopReason = reason }
            case "rate_limit_event":
                if let info = event.rateLimitInfo {
                    limitRejected = info.status == "rejected"
                    limitResetsAt = info.resetsAt.map { Date(timeIntervalSince1970: $0) }
                }
            case "result":
                return .finished(try result(of: event))
            default:
                break
            }
            return nil
        }

        private func result(of event: Event) throws -> GenerationResult {
            let text = event.result ?? ""
            if event.isError == true { throw error(text: text, status: event.apiErrorStatus) }
            let usage = event.usage.map {
                TokenUsage(inputTokens: $0.inputTokens + ($0.cacheCreationInputTokens ?? 0) + ($0.cacheReadInputTokens ?? 0),
                           outputTokens: $0.outputTokens)
            }
            let answering = event.modelUsage?.keys.sorted().first.map(ModelID.init(rawValue:)) ?? model ?? requested
            let reason = event.stopReason ?? stopReason
            let finish: FinishReason = reason == "refusal" ? .contentFilter : FinishReason(chatCompletions: reason)
            return GenerationResult(text: text, provider: provider, model: answering, usage: usage, latency: .zero,
                                    finishReason: finish)
        }

        private func error(text: String, status: Int?) -> ProviderError {
            let lowered = text.lowercased()
            if status == 429 || limitRejected {
                let wait = limitResetsAt.map { Duration.seconds(max(0, $0.timeIntervalSinceNow.rounded(.up))) }
                return ProviderError(.rateLimited(retryAfter: wait), text, provider: provider, status: status)
            }
            switch status {
            case 401, 403: return ProviderError(.unavailable(.notSignedIn), text, provider: provider, status: status)
            case 413: return ProviderError(.contextExceeded, text, provider: provider, status: status)
            case 400, 404: return ProviderError(.invalidRequest, text, provider: provider, status: status)
            case let code? where (500...599).contains(code):
                return ProviderError(.server, text, provider: provider, status: status)
            default: break
            }
            if lowered.contains("not logged in") || lowered.contains("/login") {
                return ProviderError(.unavailable(.notSignedIn), text, provider: provider, status: status)
            }
            if lowered.contains("prompt is too long") {
                return ProviderError(.contextExceeded, text, provider: provider, status: status)
            }
            return ProviderError(.server, text, provider: provider, status: status)
        }
    }

    struct Event: Decodable {
        var type: String
        var subtype: String?
        var model: String?
        var apiKeySource: String?
        var event: Inner?
        var rateLimitInfo: RateLimit?
        var isError: Bool?
        var result: String?
        var stopReason: String?
        var apiErrorStatus: Int?
        var usage: Usage?
        var modelUsage: [String: Ignored]?

        struct Inner: Decodable {
            var delta: Delta?
        }

        struct Delta: Decodable {
            var type: String?
            var text: String?
            var stopReason: String?

            enum CodingKeys: String, CodingKey {
                case type, text
                case stopReason = "stop_reason"
            }
        }

        struct RateLimit: Decodable {
            var status: String?
            var resetsAt: Double?
        }

        struct Usage: Decodable {
            var inputTokens: Int
            var outputTokens: Int
            var cacheCreationInputTokens: Int?
            var cacheReadInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
            }
        }

        struct Ignored: Decodable {}

        enum CodingKeys: String, CodingKey {
            case type, subtype, model, apiKeySource, event, result, usage, modelUsage
            case rateLimitInfo = "rate_limit_info"
            case isError = "is_error"
            case stopReason = "stop_reason"
            case apiErrorStatus = "api_error_status"
        }
    }
}

/// Where `claude` is installed. A Finder-launched app does not see the user's shell
/// PATH, so the known install locations are checked in order.
public enum ClaudeCodeLocator {
    public static let candidates = [
        "~/.local/bin/claude",          // the native installer
        "~/.claude/local/claude",       // the older local install
        "/opt/homebrew/bin/claude",     // Homebrew, Apple silicon
        "/usr/local/bin/claude",        // Homebrew, Intel; global npm
        "~/.npm-global/bin/claude",
        "~/.bun/bin/claude",
        "~/.volta/bin/claude",
    ]

    /// The known install locations, then every folder on this process's PATH — which the
    /// app widens at launch with the user's shell PATH (AppCore `LoginShellPath`), so an
    /// install that only `~/.zshrc` knows about (nvm, pnpm, a custom prefix) is found too.
    @Sendable public static func standard() -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let onPath = path.split(separator: ":").map { "\($0)/claude" }
        return locate(in: candidates + onPath, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    static func locate(in candidates: [String], home: String,
                       isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        candidates
            .map { $0.hasPrefix("~/") ? home + $0.dropFirst() : $0 }
            .first(where: isExecutable)
            .map { URL(filePath: $0) }
    }
}
