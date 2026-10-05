import Foundation

/// A provider that speaks the OpenAI **Chat Completions** wire protocol.
///
/// OpenAI, OpenRouter and Vercel AI Gateway all expose it, as do local servers
/// such as Ollama and LM Studio, so one adapter covers them and each "provider"
/// is a preset: an endpoint, a descriptor and a couple of dialect switches.
/// The unit of adaptation is the wire protocol, not the company — a vendor
/// with its own protocol gets its own adapter type, not a preset.
public struct ChatCompletionsProvider: ModelProvider {
    public let descriptor: ProviderDescriptor
    public let endpoint: Endpoint
    private let credentials: any CredentialStore
    private let transport: any HTTPTransport
    private let recommended: Set<ModelID>

    /// Where to send requests and the small differences between dialects.
    public struct Endpoint: Sendable, Hashable {
        /// Base URL up to and including the version segment, e.g. `https://api.openai.com/v1`.
        public var baseURL: URL
        /// Static headers every request carries (attribution, routing).
        public var headers: [String: String]
        /// OpenAI renamed `max_tokens` to `max_completion_tokens`; the other
        /// implementations still read the old name.
        public var maxTokensField: String
        /// The vendor of models whose ids carry no `creator/` prefix — `openai` for
        /// OpenAI's own catalogue (canonical model identity, ARCHITECTURE §5.1).
        public var defaultVendor: String?
        /// OpenRouter's `provider` routing object, sent with every generation —
        /// `data_collection: deny` routes only to inference providers that do not
        /// collect prompts (PROVIDERS §8 item 5).
        public var routingPreferences: [String: String]?

        public init(baseURL: URL, headers: [String: String] = [:], maxTokensField: String = "max_tokens",
                    defaultVendor: String? = nil, routingPreferences: [String: String]? = nil) {
            self.baseURL = baseURL
            self.headers = headers
            self.maxTokensField = maxTokensField
            self.defaultVendor = defaultVendor
            self.routingPreferences = routingPreferences
        }
    }

    public init(descriptor: ProviderDescriptor, endpoint: Endpoint, credentials: any CredentialStore,
                transport: any HTTPTransport = URLSessionTransport(), recommended: [ModelID] = []) {
        self.descriptor = descriptor
        self.endpoint = endpoint
        self.credentials = credentials
        self.transport = transport
        self.recommended = Set(recommended)
    }

    // MARK: - ModelProvider

    public func availability() async -> ProviderAvailability {
        guard descriptor.traits.credential == .apiKey else { return .available }
        let key = (try? credentials.secret(for: id)) ?? nil
        return (key?.isEmpty ?? true) ? .unavailable(.missingCredential) : .available
    }

    public func models() async throws -> [ModelDescriptor] {
        do {
            let request = try makeRequest(path: "models", method: "GET", body: nil)
            let (data, response) = try await transport.data(for: request)
            guard (200..<300).contains(response.statusCode) else {
                throw Self.mapHTTPError(status: response.statusCode, body: data, headers: response, provider: id)
            }
            let list: ModelList
            do {
                list = try JSONDecoder().decode(ModelList.self, from: data)
            } catch {
                throw ProviderError(.malformedResponse, "Unreadable model list: \(error)", provider: id)
            }
            return list.data
                .map { ModelDescriptor(id: ModelID(rawValue: $0.id), displayName: $0.name,
                                       contextTokens: $0.contextLength ?? $0.contextWindow,
                                       isRecommended: recommended.contains(ModelID(rawValue: $0.id)),
                                       pricing: $0.pricing?.perMillion,
                                       vendor: Self.vendor(of: $0.id, default: endpoint.defaultVendor)) }
                .sorted { ($0.isRecommended ? 0 : 1, $0.displayName) < ($1.isRecommended ? 0 : 1, $1.displayName) }
        } catch {
            throw ProviderError.normalize(error, provider: id)
        }
    }

    public func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error> {
        let provider = id
        return GenerationStream.make(provider: provider, timeout: request.options.timeout) { continuation in
            let started = ContinuousClock.now
            let urlRequest = try makeRequest(path: "chat/completions", method: "POST", body: try encodeBody(request))
            let (response, lines) = try await transport.lines(for: urlRequest)

            guard (200..<300).contains(response.statusCode) else {
                var body = ""
                for try await line in lines { body += line + "\n" }
                throw Self.mapHTTPError(status: response.statusCode, body: Data(body.utf8), headers: response, provider: provider)
            }

            var text = ""
            var finish: String?
            var answeringModel = request.model
            var usage: TokenUsage?
            let decoder = JSONDecoder()

            for try await line in lines {
                try Task.checkCancellation()
                // SSE: only `data:` lines carry payload; `:` lines are keep-alive comments.
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }

                let chunk: StreamChunk
                do {
                    chunk = try decoder.decode(StreamChunk.self, from: Data(payload.utf8))
                } catch {
                    throw ProviderError(.malformedResponse, "Unreadable stream chunk: \(payload.prefix(200))", provider: provider)
                }
                // Some gateways report failures inside a 200 stream.
                if let error = chunk.error {
                    throw Self.mapErrorBody(error, status: error.httpStatus ?? 502, retryAfter: nil, provider: provider)
                }
                if let model = chunk.model { answeringModel = ModelID(rawValue: model) }
                if let u = chunk.usage { usage = TokenUsage(inputTokens: u.promptTokens, outputTokens: u.completionTokens) }
                if let reason = chunk.choices?.first?.finishReason { finish = reason }
                if let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty {
                    text += delta
                    continuation.yield(.delta(delta))
                }
            }
            try Task.checkCancellation()

            continuation.yield(.completed(GenerationResult(
                text: text, provider: provider, model: answeringModel, usage: usage, latency: started.elapsed,
                finishReason: FinishReason(chatCompletions: finish))))
        }
    }

    // MARK: - Request building

    func encodeBody(_ request: GenerationRequest) throws -> Data {
        var messages: [[String: String]] = [["role": "system", "content": request.instructions]]
        for example in request.examples {
            messages.append(["role": "user", "content": example.input])
            messages.append(["role": "assistant", "content": example.output])
        }
        messages.append(["role": "user", "content": request.input])

        var body: [String: Any] = [
            "model": request.model.rawValue,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if let temperature = request.options.temperature { body["temperature"] = temperature }
        if let maxTokens = request.options.maxOutputTokens { body[endpoint.maxTokensField] = maxTokens }
        if let routing = endpoint.routingPreferences { body["provider"] = routing }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private func makeRequest(path: String, method: String, body: Data?) throws -> URLRequest {
        var request = URLRequest(url: endpoint.baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in endpoint.headers { request.setValue(value, forHTTPHeaderField: name) }
        if descriptor.traits.credential == .apiKey {
            guard let key = try credentials.secret(for: id), !key.isEmpty else {
                throw ProviderError(.unavailable(.missingCredential), "No API key stored for \(descriptor.displayName).", provider: id)
            }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// `anthropic` for `anthropic/claude-…`; the endpoint's default vendor otherwise.
    static func vendor(of modelID: String, default defaultVendor: String?) -> String? {
        if let slash = modelID.firstIndex(of: "/"), slash != modelID.startIndex {
            return String(modelID[..<slash]).lowercased()
        }
        return defaultVendor
    }

    // MARK: - Error mapping

    static func mapHTTPError(status: Int, body: Data, headers: HTTPURLResponse, provider: ProviderID) -> ProviderError {
        let retryAfter = headers.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init).map { Duration.seconds($0) }
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body)
        let error = envelope?.error ?? ErrorBody(message: String(data: body, encoding: .utf8)?.prefix(300).description)
        return mapErrorBody(error, status: status, retryAfter: retryAfter, provider: provider)
    }

    static func mapErrorBody(_ error: ErrorBody, status: Int, retryAfter: Duration?, provider: ProviderID) -> ProviderError {
        let message = error.message ?? "HTTP \(status)"
        let code = error.code?.lowercased() ?? ""
        let type = error.type?.lowercased() ?? ""
        let mapped: ProviderError.Code
        if code.contains("context_length") || message.lowercased().contains("context length") {
            mapped = .contextExceeded
        } else if code.contains("content_filter") || code.contains("moderation") || status == 451 {
            mapped = .refused
        } else {
            switch status {
            case 401, 403: mapped = .authentication
            case 402, 429: mapped = .rateLimited(retryAfter: retryAfter)
            case 408, 504: mapped = .timeout
            case 400, 404, 413, 422: mapped = type.contains("insufficient_quota") ? .rateLimited(retryAfter: retryAfter) : .invalidRequest
            case 500...: mapped = .server
            default: mapped = .server
            }
        }
        return ProviderError(mapped, message, provider: provider, status: status)
    }

    // MARK: - Wire types

    struct ModelList: Decodable {
        struct Entry: Decodable {
            let id: String
            let name: String?
            let contextLength: Int?
            let contextWindow: Int?
            let pricing: Pricing?
            enum CodingKeys: String, CodingKey {
                case id, name, pricing
                case contextLength = "context_length"
                case contextWindow = "context_window"
            }
        }
        /// Per-token prices as decimal strings: OpenRouter names them `prompt` and
        /// `completion`, the Vercel gateway `input` and `output`.
        struct Pricing: Decodable {
            let input: String?
            let output: String?
            enum CodingKeys: String, CodingKey { case prompt, completion, input, output }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                input = try Self.price(container, .prompt) ?? Self.price(container, .input)
                output = try Self.price(container, .completion) ?? Self.price(container, .output)
            }

            private static func price(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> String? {
                if let text = try? container.decodeIfPresent(String.self, forKey: key) { return text }
                if let number = try? container.decodeIfPresent(Double.self, forKey: key) { return String(number) }
                return nil
            }

            var perMillion: ModelPricing? {
                guard let input = input.flatMap(Double.init), let output = output.flatMap(Double.init),
                      input >= 0, output >= 0 else { return nil }
                return ModelPricing(inputPerMillion: input * 1_000_000, outputPerMillion: output * 1_000_000)
            }
        }
        let data: [Entry]
    }

    struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
            let finishReason: String?
            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }
        struct Usage: Decodable {
            let promptTokens: Int
            let completionTokens: Int
            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
            }
        }
        let model: String?
        let choices: [Choice]?
        let usage: Usage?
        let error: ErrorBody?
    }

    struct ErrorEnvelope: Decodable { let error: ErrorBody }

    struct ErrorBody: Decodable {
        var message: String?
        var type: String?
        var code: String?
        var httpStatus: Int?

        init(message: String?) { self.message = message }

        enum CodingKeys: String, CodingKey { case message, type, code }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            // OpenAI sends `code` as a string; OpenRouter sends the HTTP status as a number.
            if let text = try? container.decodeIfPresent(String.self, forKey: .code) {
                code = text
            } else if let number = try? container.decodeIfPresent(Int.self, forKey: .code) {
                httpStatus = number
            }
        }
    }
}
