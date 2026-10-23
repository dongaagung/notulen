import Foundation

/// One turn of a conversation, the same for every provider.
struct ChatMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case user, assistant
    }

    var role: Role
    var content: String
}

/// What the app asks a model for, in provider-neutral terms. Each client
/// turns the purpose into its own model choice and settings.
struct LLMRequest: Sendable {
    enum Purpose: Sendable {
        /// The running notes per topic during a meeting. Latency-bound.
        case liveNotes
        /// The meeting's minutes. JSON reply.
        case minutes
        /// Minutes translated into another language. JSON reply.
        case translation

        /// Live notes need speed; the rest need judgment.
        var needsSpeed: Bool { self == .liveNotes }
    }

    var purpose: Purpose
    var system: String
    var messages: [ChatMessage]
    var maxTokens: Int
    /// When set, the reply must be one JSON object matching this schema.
    var jsonSchema: JSONValue?
}

/// A model provider: Claude's own API, or any OpenAI-compatible one.
protocol LLMClient: Sendable {
    /// For messages, such as "Claude" or "Groq".
    var providerName: String { get }
    /// Streams the reply's text as it's generated.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, any Error>
    /// The whole reply's text.
    func complete(_ request: LLMRequest) async throws -> String
    /// Gets the next real request of this shape ready (prompt cache, open
    /// connection). Providers without a way to do that do nothing.
    func prewarm(_ request: LLMRequest) async throws
}

extension LLMClient {
    func prewarm(_ request: LLMRequest) async throws {}

    /// The whole reply's text, read from the stream. Minutes and translation
    /// run long, and a non-streaming request that long can time out.
    func completeStreaming(_ request: LLMRequest) async throws -> String {
        var text = ""
        for try await delta in stream(request) { text += delta }
        return text
    }
}

/// Reads JSON replies, including ones a model wrapped in prose or fences.
enum JSONReply {
    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try ClaudeClient.decoder.decode(T.self, from: Data(object(in: text).utf8))
    }

    /// From the first "{" to the last "}", or the text as is.
    static func object(in text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return text
        }
        return String(text[start...end])
    }
}
