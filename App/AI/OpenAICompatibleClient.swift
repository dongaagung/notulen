import Foundation

/// Any provider that speaks OpenAI's chat-completions API: OpenAI, Gemini,
/// DeepSeek, Groq, OpenRouter, Ollama and others.
struct OpenAICompatibleClient: LLMClient {
    enum Failure: LocalizedError, Equatable {
        case http(provider: String, status: Int, message: String)
        case api(provider: String, message: String)
        case badResponse(provider: String)
        /// The reply hit the token limit and is cut off.
        case truncated

        var errorDescription: String? {
            switch self {
            case .http(let provider, 401, _), .http(let provider, 403, _):
                "Kunci API \(provider) ditolak. Periksa di Pengaturan."
            case .http(let provider, 404, let message):
                "\(provider) tidak mengenal alamat atau model itu (\(message)). Periksa alamat server dan model di Pengaturan."
            case .http(let provider, let status, let message): "Kesalahan \(provider) \(status): \(message)"
            case .api(let provider, let message): "Kesalahan \(provider): \(message)"
            case .badResponse(let provider): "Respons \(provider) tidak terduga."
            case .truncated: "Jawaban AI terpotong. Coba lagi."
            }
        }

        var status: Int? {
            if case .http(_, let status, _) = self { return status }
            return nil
        }

        var isRetryable: Bool {
            [408, 429, 500, 502, 503, 504, 529].contains(status ?? 0)
        }
    }

    /// How to get JSON back. Not every server supports JSON schemas, so a
    /// request that's refused falls back to the next mode.
    enum JSONMode: CaseIterable, Sendable {
        case schema
        case object
        case instructions
    }

    let providerName: String
    let baseURL: URL
    let apiKey: String?
    let fastModel: String
    let smartModel: String
    var usesMaxCompletionTokens = false
    var session: URLSession = .shared

    // MARK: LLMClient

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await open(request) { mode in
                        let (bytes, response) = try await session.bytes(for: urlRequest(body(for: request, stream: true, json: mode)))
                        try await check(response, bytes: bytes)
                        return bytes
                    }
                    for try await line in bytes.lines {
                        switch Self.decode(line: line) {
                        case .text(let text): continuation.yield(text)
                        case .error(let message): throw Failure.api(provider: providerName, message: message)
                        case .truncated: throw Failure.truncated
                        case .done: break
                        case nil: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func complete(_ request: LLMRequest) async throws -> String {
        try await open(request) { mode in
            let (data, response) = try await session.data(for: urlRequest(body(for: request, stream: false, json: mode)))
            try check(response, body: data)
            struct Reply: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable { let content: String? }
                    let message: Message
                    let finishReason: String?

                    enum CodingKeys: String, CodingKey {
                        case message
                        case finishReason = "finish_reason"
                    }
                }
                let choices: [Choice]
            }
            guard let choice = try? JSONDecoder().decode(Reply.self, from: data).choices.first,
                  let text = choice.message.content
            else {
                throw Failure.badResponse(provider: providerName)
            }
            if choice.finishReason == "length" { throw Failure.truncated }
            return text
        }
    }

    /// Lists the models the server offers, for the pickers in Pengaturan.
    static func listModels(baseURL: URL, apiKey: String?, session: URLSession = .shared) async throws -> [String] {
        var request = URLRequest(url: baseURL.appending(path: "models"), timeoutInterval: 20)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse(provider: baseURL.host() ?? "") }
        guard http.statusCode == 200 else {
            throw Failure.http(provider: baseURL.host() ?? "", status: http.statusCode, message: Self.errorMessage(in: data))
        }
        struct List: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        return try JSONDecoder().decode(List.self, from: data).data.map(\.id).sorted()
    }

    // MARK: Requests

    struct Body: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let stream: Bool
        let maxTokens: Int?
        let maxCompletionTokens: Int?
        let responseFormat: JSONValue?

        enum CodingKeys: String, CodingKey {
            case model, messages, stream
            case maxTokens = "max_tokens"
            case maxCompletionTokens = "max_completion_tokens"
            case responseFormat = "response_format"
        }
    }

    func body(for request: LLMRequest, stream: Bool, json mode: JSONMode?) -> Body {
        var system = request.system
        var responseFormat: JSONValue?
        if let schema = request.jsonSchema, let mode {
            switch mode {
            case .schema:
                responseFormat = ["type": "json_schema", "json_schema": ["name": "reply", "strict": true, "schema": schema]]
            case .object:
                responseFormat = ["type": "json_object"]
                system += Self.jsonInstructions(schema)
            case .instructions:
                system += Self.jsonInstructions(schema)
            }
        }
        let messages = [Body.Message(role: "system", content: system)]
            + request.messages.map { Body.Message(role: $0.role.rawValue, content: $0.content) }
        return Body(
            model: request.purpose.needsSpeed ? fastModel : smartModel,
            messages: messages,
            stream: stream,
            maxTokens: usesMaxCompletionTokens ? nil : request.maxTokens,
            maxCompletionTokens: usesMaxCompletionTokens ? request.maxTokens : nil,
            responseFormat: responseFormat)
    }

    func urlRequest(_ body: Body) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appending(path: "chat/completions"), timeoutInterval: 60)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }
        urlRequest.httpBody = try ClaudeClient.encoder.encode(body)
        return urlRequest
    }

    private static func jsonInstructions(_ schema: JSONValue) -> String {
        let schemaText = (try? ClaudeClient.encoder.encode(schema)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return "\n\nBalas hanya dengan satu objek JSON, tanpa teks lain, sesuai JSON schema ini:\n\(schemaText)"
    }

    /// Opens the request, retrying once on overload and, for JSON requests,
    /// stepping down the JSON modes while the server refuses them (400).
    private func open<T>(_ request: LLMRequest, _ attempt: (JSONMode?) async throws -> T) async throws -> T {
        let modes: [JSONMode?] = request.jsonSchema == nil ? [nil] : JSONMode.allCases
        for (index, mode) in modes.enumerated() {
            do {
                do {
                    return try await attempt(mode)
                } catch let failure as Failure where failure.isRetryable {
                    try await Task.sleep(for: .milliseconds(400))
                    return try await attempt(mode)
                }
            } catch let failure as Failure where failure.status == 400 && index < modes.count - 1 {
                continue
            }
        }
        throw Failure.badResponse(provider: providerName)
    }

    private func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse(provider: providerName) }
        guard http.statusCode != 200 else { return }
        throw Failure.http(provider: providerName, status: http.statusCode, message: Self.errorMessage(in: body))
    }

    private func check(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse(provider: providerName) }
        guard http.statusCode != 200 else { return }
        var body = Data()
        for try await byte in bytes.prefix(16_384) { body.append(byte) }
        throw Failure.http(provider: providerName, status: http.statusCode, message: Self.errorMessage(in: body))
    }

    private static func errorMessage(in body: Data) -> String {
        struct Envelope: Decodable {
            struct Body: Decodable { let message: String? }
            let error: Body?
        }
        // Some servers send a list of errors.
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: body), let message = envelope.error?.message {
            return message
        }
        if let list = try? JSONDecoder().decode([Envelope].self, from: body), let message = list.first?.error?.message {
            return message
        }
        return String(decoding: body.prefix(300), as: UTF8.self)
    }

    // MARK: Streaming

    enum StreamEvent: Equatable {
        case text(String)
        case error(String)
        /// The token limit cut the reply off.
        case truncated
        case done
    }

    /// One SSE line of a streamed chat completion.
    static func decode(line: String) -> StreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta?
                let finishReason: String?

                enum CodingKeys: String, CodingKey {
                    case delta
                    case finishReason = "finish_reason"
                }
            }
            struct ErrorBody: Decodable { let message: String? }
            let choices: [Choice]?
            let error: ErrorBody?
        }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) else { return nil }
        if let error = chunk.error { return .error(error.message ?? "Kesalahan tidak diketahui") }
        if chunk.choices?.first?.finishReason == "length" { return .truncated }
        guard let text = chunk.choices?.first?.delta?.content, !text.isEmpty else { return nil }
        return .text(text)
    }
}
