import Foundation

/// Generations on the user's ChatGPT plan, through OpenAI's Responses API with the
/// access token of Sign in with ChatGPT (quill J-23). The preview's rules apply to every
/// request: `store: false`, `stream: true`, and no `temperature` or `max_output_tokens`
/// (https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations).
public struct ChatGPTPlanProvider: ModelProvider {
    public let descriptor: ProviderDescriptor
    private let session: ChatGPTSession
    private let transport: any HTTPTransport
    private let recommended: Set<ModelID>

    public init(session: ChatGPTSession, transport: any HTTPTransport = URLSessionTransport(), recommended: [ModelID] = []) {
        self.descriptor = ProviderDescriptor(
            id: ChatGPTPlan.providerID,
            displayName: "ChatGPT",
            traits: ProviderTraits(execution: .remote(recipients: [.named("OpenAI")]), cost: .includedInPlan,
                                   credential: .accountSignIn("ChatGPT")),
            notes: [.singleRecipient, .strongModels, .singleVendorCatalog])
        self.session = session
        self.transport = transport
        self.recommended = Set(recommended)
    }

    // MARK: - ModelProvider

    public func availability() async -> ProviderAvailability {
        session.account() == nil ? .unavailable(.notSignedIn) : .available
    }

    /// The signed-in account's own catalogue, in the server's order, recommended first.
    public func models() async throws -> [ModelDescriptor] {
        do {
            let (data, response) = try await authorized { token in
                var request = URLRequest(url: ChatGPTPlan.apiBaseURL.appending(path: "models"))
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return try await transport.data(for: request)
            }
            guard (200..<300).contains(response.statusCode) else {
                throw Self.mapHTTPError(status: response.statusCode, body: data, provider: id)
            }
            let list: ModelList
            do {
                list = try JSONDecoder().decode(ModelList.self, from: data)
            } catch {
                throw ProviderError(.malformedResponse, "Unreadable model list.", provider: id)
            }
            let all = list.models.filter { $0.visibility == nil || $0.visibility == "list" }.map {
                ModelDescriptor(id: ModelID(rawValue: $0.slug), displayName: $0.displayName ?? $0.slug,
                                isRecommended: recommended.contains(ModelID(rawValue: $0.slug)), vendor: "openai")
            }
            return all.filter(\.isRecommended) + all.filter { !$0.isRecommended }
        } catch {
            throw ProviderError.normalize(error, provider: id)
        }
    }

    public func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error> {
        let provider = id
        return GenerationStream.make(provider: provider, timeout: request.options.timeout) { continuation in
            let started = ContinuousClock.now
            let body = try Self.encodeBody(request)
            var (response, lines) = try await transport.lines(for: Self.responsesRequest(body: body, token: try await session.accessToken()))
            if response.statusCode == 401 {
                (response, lines) = try await transport.lines(
                    for: Self.responsesRequest(body: body, token: try await session.refreshAfterRejection()))
            }
            guard (200..<300).contains(response.statusCode) else {
                var text = ""
                for try await line in lines { text += line + "\n" }
                throw Self.mapHTTPError(status: response.statusCode, body: Data(text.utf8), provider: provider)
            }

            var text = ""
            for try await line in lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let event = try? JSONDecoder().decode(StreamEvent.self, from: Data(payload.utf8)) else { continue }
                switch event.type {
                case "response.output_text.delta":
                    if let delta = event.delta, !delta.isEmpty {
                        text += delta
                        continuation.yield(.delta(delta))
                    }
                case "response.completed", "response.incomplete":
                    let reason = event.response?.incompleteDetails?.reason
                    let finish: FinishReason = switch reason {
                    case nil: .stop
                    case "max_output_tokens": .length
                    case "content_filter": .contentFilter
                    default: .unknown
                    }
                    continuation.yield(.completed(GenerationResult(
                        text: text, provider: provider, model: event.response?.model.map(ModelID.init(rawValue:)) ?? request.model,
                        usage: event.response?.usage.map { TokenUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens) },
                        latency: started.elapsed, finishReason: finish)))
                    return
                case "response.failed", "error":
                    let error = event.response?.error ?? event.error ?? .init(code: event.code, message: event.message)
                    throw Self.mapCode(error.code, status: nil, message: error.message ?? "The response failed.", provider: provider)
                default:
                    continue
                }
            }
            throw ProviderError(.malformedResponse, "The stream ended without response.completed.", provider: provider)
        }
    }

    // MARK: - Requests

    /// Runs `send` with a token, and once more with a refreshed one if the API answers 401.
    private func authorized<Value>(_ send: (String) async throws -> (Value, HTTPURLResponse)) async throws -> (Value, HTTPURLResponse) {
        let first = try await send(try await session.accessToken())
        guard first.1.statusCode == 401 else { return first }
        return try await send(try await session.refreshAfterRejection())
    }

    static func responsesRequest(body: Data, token: String) -> URLRequest {
        var request = URLRequest(url: ChatGPTPlan.apiBaseURL.appending(path: "responses"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Instructions as `instructions` (system items are rejected), examples as turns, the
    /// text last. Temperature and the output limit are unsupported in the preview.
    static func encodeBody(_ request: GenerationRequest) throws -> Data {
        var input: [[String: String]] = []
        for example in request.examples {
            input.append(["role": "user", "content": example.input])
            input.append(["role": "assistant", "content": example.output])
        }
        input.append(["role": "user", "content": request.input])
        let body: [String: Any] = [
            "model": request.model.rawValue,
            "instructions": request.instructions,
            "input": input,
            "store": false,
            "stream": true,
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    // MARK: - Errors (Errors and recovery, read 2026-11-11)

    static func mapHTTPError(status: Int, body: Data, provider: ProviderID) -> ProviderError {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let message = (error?["message"] as? String) ?? (object?["detail"] as? String) ?? "HTTP \(status)"
        return mapCode(error?["code"] as? String, status: status, message: message, provider: provider)
    }

    static func mapCode(_ code: String?, status: Int?, message: String, provider: ProviderID) -> ProviderError {
        let mapped: ProviderError.Code = switch code {
        case "subscription_sharing_usage_limit_exceeded": .rateLimited(retryAfter: nil)
        case "subscription_sharing_user_not_eligible": .unavailable(.planNotEligible)
        case "subscription_sharing_invalid_user": .unavailable(.notSignedIn)
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": .server
        case "subscription_sharing_unsupported_capability", "subscription_sharing_route_not_supported",
             "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context": .invalidRequest
        case "context_length_exceeded": .contextExceeded
        default:
            switch status {
            case 401: .unavailable(.notSignedIn)
            case 403: .unavailable(.planNotEligible)
            case 429: .rateLimited(retryAfter: nil)
            case 400, 404, 422: .invalidRequest
            case .some(let value) where value >= 500: .server
            default: .server
            }
        }
        return ProviderError(mapped, message, provider: provider, status: status)
    }

    // MARK: - Wire types

    struct ModelList: Decodable {
        struct Model: Decodable {
            var slug: String
            var displayName: String?
            var visibility: String?
            enum CodingKeys: String, CodingKey {
                case slug, visibility
                case displayName = "display_name"
            }
        }
        var models: [Model]
    }

    struct StreamEvent: Decodable {
        var type: String
        var delta: String?
        var response: Response?
        var error: APIError?
        var code: String?
        var message: String?

        struct Response: Decodable {
            var model: String?
            var usage: Usage?
            var incompleteDetails: IncompleteDetails?
            var error: APIError?
            enum CodingKeys: String, CodingKey {
                case model, usage, error
                case incompleteDetails = "incomplete_details"
            }
        }

        struct IncompleteDetails: Decodable {
            var reason: String?
        }

        struct Usage: Decodable {
            var inputTokens: Int
            var outputTokens: Int
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }

        struct APIError: Decodable {
            var code: String?
            var message: String?
        }
    }
}
