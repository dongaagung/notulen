import Foundation

enum ClaudeModel {
    /// Live notes, where latency matters most.
    static let haiku = "claude-haiku-5-5"
    /// Minutes and translation.
    static let sonnet = "claude-sonnet-5-5"
}

/// Body of a Messages API request.
struct MessageRequest: Encodable, Sendable {
    struct SystemBlock: Encodable, Sendable {
        var type = "text"
        var text: String
        var cacheControl: CacheControl?

        enum CodingKeys: String, CodingKey {
            case type, text
            case cacheControl = "cache_control"
        }
    }

    struct CacheControl: Encodable, Sendable {
        var type = "ephemeral"
    }

    typealias Message = ChatMessage

    struct Thinking: Encodable, Sendable {
        var type: String

        /// Haiku 5.5 accepts this at effort `high` or below.
        static let disabled = Thinking(type: "disabled")
        static let adaptive = Thinking(type: "adaptive")
    }

    struct OutputConfig: Encodable, Sendable {
        struct Format: Encodable, Sendable {
            var type = "json_schema"
            var schema: JSONValue
        }

        var effort: String?
        var format: Format?
    }

    var model: String
    var maxTokens: Int
    var system: [SystemBlock]
    var messages: [Message]
    var stream: Bool?
    var thinking: Thinking?
    var outputConfig: OutputConfig?
    /// Server-side refusal fallback. Sonnet 5.5 only: Haiku 5.5 has none.
    var fallbacks: String?

    /// Beta headers the body needs. Not encoded.
    var betas: [String] {
        fallbacks == nil ? [] : ["server-side-fallback-2026-07-01"]
    }

    enum CodingKeys: String, CodingKey {
        case model, system, messages, stream, thinking, fallbacks
        case maxTokens = "max_tokens"
        case outputConfig = "output_config"
    }
}

struct MessageResponse: Decodable, Sendable {
    struct Block: Decodable, Sendable {
        let type: String
        let text: String?
    }

    struct Usage: Decodable, Sendable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?
    }

    let content: [Block]
    let stopReason: String?
    let usage: Usage?

    /// Text blocks only, read by type: a response can start with thinking blocks.
    var text: String {
        content.filter { $0.type == "text" }.compactMap(\.text).joined()
    }
}

/// The parts of a streamed response this app uses.
enum StreamEvent: Equatable, Sendable {
    case text(String)
    case stopReason(String?)
    case messageStop
    case error(type: String, message: String)

    /// Decodes one SSE line. Returns nil for `event:` lines, pings, thinking
    /// deltas and other events that carry nothing used here. Each Messages API
    /// event is a single `data:` line whose JSON names its own type.
    static func decode(line: String) -> StreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let event = try? ClaudeClient.decoder.decode(RawEvent.self, from: Data(json.utf8)) else { return nil }
        switch event.type {
        case "content_block_delta":
            guard event.delta?.type == "text_delta", let text = event.delta?.text else { return nil }
            return .text(text)
        case "message_delta":
            return .stopReason(event.delta?.stopReason)
        case "message_stop":
            return .messageStop
        case "error":
            return .error(type: event.error?.type ?? "error", message: event.error?.message ?? "Kesalahan tidak diketahui")
        default:
            return nil
        }
    }

    private struct RawEvent: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let stopReason: String?
        }

        struct ErrorBody: Decodable {
            let type: String?
            let message: String?
        }

        let type: String
        let delta: Delta?
        let error: ErrorBody?
    }
}

/// Messages API over URLSession. There's no official Swift SDK, so this
/// speaks raw HTTP + SSE.
struct ClaudeClient: Sendable {
    enum Failure: LocalizedError, Equatable {
        case http(status: Int, message: String)
        case api(type: String, message: String)
        case refusal
        /// The reply hit the token limit and is cut off.
        case truncated
        case badResponse

        var errorDescription: String? {
            switch self {
            case .http(401, _): "Kunci API Anthropic ditolak. Periksa di Pengaturan."
            case .http(let status, let message): "Kesalahan API Claude \(status): \(message)"
            case .api(_, let message): "Kesalahan API Claude: \(message)"
            case .refusal: "Claude menolak menjawab permintaan ini."
            case .truncated: "Jawaban AI terpotong. Coba lagi."
            case .badResponse: "Respons API Claude tidak terduga."
            }
        }

        var isRetryable: Bool {
            switch self {
            case .http(let status, _): [408, 429, 500, 502, 503, 504, 529].contains(status)
            case .api(let type, _): type == "overloaded_error" || type == "api_error"
            default: false
            }
        }
    }

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    let apiKey: String
    var session: URLSession = .shared

    func send(_ request: MessageRequest) async throws -> MessageResponse {
        var request = request
        request.stream = nil
        return try await withOneRetry {
            let (data, response) = try await session.data(for: urlRequest(for: request))
            try Self.check(response, body: data)
            let message = try Self.decoder.decode(MessageResponse.self, from: data)
            if message.stopReason == "refusal" { throw Failure.refusal }
            if message.stopReason == "max_tokens" { throw Failure.truncated }
            return message
        }
    }

    /// Streams text deltas. Throws `Failure.refusal` at the end if Claude declined, `Failure.truncated` if the token limit cut the reply off.
    func stream(_ request: MessageRequest) -> AsyncThrowingStream<String, any Error> {
        var request = request
        request.stream = true
        let urlRequest: URLRequest
        do {
            urlRequest = try self.urlRequest(for: request)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await withOneRetry {
                        let (bytes, response) = try await session.bytes(for: urlRequest)
                        try await Self.check(response, bytes: bytes)
                        return bytes
                    }
                    var stopReason: String?
                    for try await line in bytes.lines {
                        switch StreamEvent.decode(line: line) {
                        case .text(let text): continuation.yield(text)
                        case .stopReason(let reason): stopReason = reason ?? stopReason
                        case .error(let type, let message): throw Failure.api(type: type, message: message)
                        case .messageStop, nil: break
                        }
                    }
                    if stopReason == "refusal" { throw Failure.refusal }
                    if stopReason == "max_tokens" { throw Failure.truncated }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func urlRequest(for request: MessageRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: Self.endpoint, timeoutInterval: 60)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !request.betas.isEmpty {
            urlRequest.setValue(request.betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try Self.encoder.encode(request)
        return urlRequest
    }

    /// One quick retry on overload and transient errors. Live notes are
    /// latency-bound, so there's no long backoff.
    private func withOneRetry<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let failure as Failure where failure.isRetryable {
            try await Task.sleep(for: .milliseconds(400))
            return try await operation()
        }
    }

    private static func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard http.statusCode != 200 else { return }
        throw failure(status: http.statusCode, body: body)
    }

    private static func check(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard http.statusCode != 200 else { return }
        var body = Data()
        for try await byte in bytes.prefix(16_384) { body.append(byte) }
        throw failure(status: http.statusCode, body: body)
    }

    private static func failure(status: Int, body: Data) -> Failure {
        struct ErrorEnvelope: Decodable {
            struct Body: Decodable { let type: String?; let message: String? }
            let error: Body?
        }
        let envelope = try? decoder.decode(ErrorEnvelope.self, from: body)
        let message = envelope?.error?.message ?? String(decoding: body.prefix(300), as: UTF8.self)
        return .http(status: status, message: message)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Stable bytes keep the prompt-cache prefix identical across requests.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

/// Claude through Anthropic's own API: each purpose gets the model and
/// settings tuned for it.
extension ClaudeClient: LLMClient {
    var providerName: String { "Claude" }

    func messageRequest(for request: LLMRequest) -> MessageRequest {
        var message = MessageRequest(
            model: request.purpose.needsSpeed ? ClaudeModel.haiku : ClaudeModel.sonnet,
            maxTokens: request.maxTokens,
            system: [.init(text: request.system, cacheControl: .init())],
            messages: request.messages)
        let format = request.jsonSchema.map { MessageRequest.OutputConfig.Format(schema: $0) }
        switch request.purpose {
        case .liveNotes:
            // Latency budget: Haiku with thinking off at low effort.
            message.thinking = .disabled
            message.outputConfig = .init(effort: "low", format: format)
        case .minutes:
            // The one output that must be right: thinking on, high effort.
            message.thinking = .adaptive
            message.outputConfig = .init(effort: "high", format: format)
            message.fallbacks = "default"
        case .translation:
            // Not latency-bound, so thinking stays on.
            message.thinking = .adaptive
            message.outputConfig = .init(effort: "medium", format: format)
            message.fallbacks = "default"
        }
        return message
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, any Error> {
        stream(messageRequest(for: request))
    }

    func complete(_ request: LLMRequest) async throws -> String {
        try await send(messageRequest(for: request)).text
    }

    /// Writes the system prompt into the prompt cache and opens the HTTPS
    /// connection. `max_tokens: 0` bills no output tokens. Same thinking and
    /// effort as real requests, or the cache entry wouldn't match.
    func prewarm(_ request: LLMRequest) async throws {
        var message = messageRequest(for: request)
        message.maxTokens = 0
        _ = try await send(message)
    }
}
