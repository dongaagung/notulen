import Foundation
import Testing
@testable import Notulen

private func request(
    _ purpose: LLMRequest.Purpose, schema: JSONValue? = nil, system: String = "SYSTEM"
) -> LLMRequest {
    LLMRequest(
        purpose: purpose, system: system, messages: [.init(role: .user, content: "hi")],
        maxTokens: 100, jsonSchema: schema)
}

private let replySchema: JSONValue = [
    "type": "object",
    "properties": ["ok": ["type": "boolean"]],
    "required": ["ok"],
    "additionalProperties": false,
]

struct MessageRequestTests {
    let claude = ClaudeClient(apiKey: "k")

    func json(_ purpose: LLMRequest.Purpose, schema: JSONValue? = nil) throws -> [String: Any] {
        let data = try ClaudeClient.encoder.encode(claude.messageRequest(for: request(purpose, schema: schema)))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func liveNotesUseHaikuLowEffort() throws {
        let json = try json(.liveNotes)
        #expect(json["model"] as? String == "claude-haiku-5-5")
        #expect(json["max_tokens"] as? Int == 100)
        let system = try #require((json["system"] as? [[String: Any]])?.first)
        #expect(system["text"] as? String == "SYSTEM")
        #expect((system["cache_control"] as? [String: String]) == ["type": "ephemeral"])
        #expect((json["thinking"] as? [String: String]) == ["type": "disabled"])
        #expect((json["output_config"] as? [String: String]) == ["effort": "low"])
        #expect(json["fallbacks"] == nil)
        #expect(json["stream"] == nil)
    }

    @Test func minutesUseSonnetHighEffort() throws {
        let json = try json(.minutes, schema: replySchema)
        #expect(json["model"] as? String == "claude-sonnet-5-5")
        #expect((json["thinking"] as? [String: String]) == ["type": "adaptive"])
        let config = try #require(json["output_config"] as? [String: Any])
        #expect(config["effort"] as? String == "high")
        let format = try #require(config["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(schema["required"] as? [String] == ["ok"])
        #expect(json["fallbacks"] as? String == "default")
    }

    @Test func translationUsesSonnetMedium() throws {
        let json = try json(.translation)
        #expect(json["model"] as? String == "claude-sonnet-5-5")
        #expect((json["thinking"] as? [String: String]) == ["type": "adaptive"])
        #expect((json["output_config"] as? [String: String]) == ["effort": "medium"])
        #expect(json["fallbacks"] as? String == "default")
    }

    @Test func onlyLiveNotesNeedSpeed() {
        #expect(LLMRequest.Purpose.liveNotes.needsSpeed)
        #expect(!LLMRequest.Purpose.minutes.needsSpeed)
        #expect(!LLMRequest.Purpose.translation.needsSpeed)
    }

    @Test func fallbacksAddBetaHeader() throws {
        var request = MessageRequest(model: ClaudeModel.sonnet, maxTokens: 10, system: [], messages: [])
        #expect(try ClaudeClient(apiKey: "k").urlRequest(for: request).value(forHTTPHeaderField: "anthropic-beta") == nil)
        request.fallbacks = "default"
        let urlRequest = try ClaudeClient(apiKey: "secret").urlRequest(for: request)
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "secret")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }
}

struct StreamEventTests {
    @Test func decodesTheEventsWeUse() {
        #expect(StreamEvent.decode(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#) == .text("Hi"))
        #expect(StreamEvent.decode(line: #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#) == .stopReason("end_turn"))
        #expect(StreamEvent.decode(line: #"data: {"type":"message_stop"}"#) == .messageStop)
        #expect(StreamEvent.decode(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#) == .error(type: "overloaded_error", message: "Overloaded"))
    }

    @Test func ignoresEverythingElse() {
        #expect(StreamEvent.decode(line: "event: content_block_delta") == nil)
        #expect(StreamEvent.decode(line: #"data: {"type":"ping"}"#) == nil)
        #expect(StreamEvent.decode(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#) == nil)
        #expect(StreamEvent.decode(line: "") == nil)
    }
}

/// Talks to a stubbed URLSession, never the real API.
@Suite(.serialized)
struct ClaudeClientHTTPTests {
    let client = ClaudeClient(apiKey: "test", session: StubURLProtocol.session)
    let request = MessageRequest(
        model: ClaudeModel.haiku, maxTokens: 10, system: [], messages: [.init(role: .user, content: "hi")])

    @Test func streamsTextDeltas() async throws {
        StubURLProtocol.respond(200, body: sse([
            #"{"type":"message_start","message":{"id":"m"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#,
            #"{"type":"ping"}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"{"type":"message_stop"}"#,
        ]))
        var text = ""
        for try await delta in client.stream(request) { text += delta }
        #expect(text == "Hello world")
    }

    @Test func streamRefusalThrows() async {
        StubURLProtocol.respond(200, body: sse([#"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#]))
        await #expect(throws: ClaudeClient.Failure.refusal) {
            for try await _ in client.stream(request) {}
        }
    }

    @Test func streamCutOffByTokenLimitThrowsTruncated() async {
        StubURLProtocol.respond(200, body: sse([
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"{\"a\":"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#,
        ]))
        await #expect(throws: ClaudeClient.Failure.truncated) {
            for try await _ in client.stream(request) {}
        }
        #expect(ClaudeClient.Failure.truncated.errorDescription == "Jawaban AI terpotong. Coba lagi.")
    }

    @Test func sendCutOffByTokenLimitThrowsTruncated() async {
        StubURLProtocol.respond(200, body: #"{"content":[{"type":"text","text":"{\"a\":"}],"stop_reason":"max_tokens"}"#)
        await #expect(throws: ClaudeClient.Failure.truncated) { _ = try await client.send(request) }
    }

    @Test func httpErrorCarriesAPIMessage() async {
        StubURLProtocol.respond(401, body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        await #expect(throws: ClaudeClient.Failure.http(status: 401, message: "invalid x-api-key")) {
            _ = try await client.send(request)
        }
    }

    @Test func sendReadsTextBlocksByType() async throws {
        StubURLProtocol.respond(200, body: #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\"ok\":true}"}],"stop_reason":"end_turn"}"#)
        #expect(try await client.send(request).text == #"{"ok":true}"#)
    }

    private func sse(_ events: [String]) -> String {
        events.map { "event: x\ndata: \($0)\n\n" }.joined()
    }
}

final class StubURLProtocol: URLProtocol {
    // Tests using this run serialized, so one shared response is enough.
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = Data()

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    static func respond(_ status: Int, body: String) {
        self.status = status
        self.body = Data(body.utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct OpenAICompatibleRequestTests {
    let client = OpenAICompatibleClient(
        providerName: "Groq", baseURL: URL(string: "https://api.groq.com/openai/v1")!,
        apiKey: "gsk_test", fastModel: "fast-model", smartModel: "smart-model")

    func json(_ body: OpenAICompatibleClient.Body) throws -> [String: Any] {
        let data = try ClaudeClient.encoder.encode(body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func liveNotesUseTheFastModelWithSystemFirst() throws {
        let body = try json(client.body(for: request(.liveNotes), stream: true, json: nil))
        #expect(body["model"] as? String == "fast-model")
        #expect(body["stream"] as? Bool == true)
        #expect(body["max_tokens"] as? Int == 100)
        #expect(body["max_completion_tokens"] == nil)
        #expect(body["response_format"] == nil)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[0]["content"] == "SYSTEM")
    }

    @Test(arguments: [LLMRequest.Purpose.minutes, .translation])
    func minutesAndTranslationUseTheSmartModel(purpose: LLMRequest.Purpose) throws {
        #expect(try json(client.body(for: request(purpose), stream: true, json: nil))["model"] as? String == "smart-model")
    }

    @Test func openAIGetsMaxCompletionTokens() throws {
        var openAI = client
        openAI.usesMaxCompletionTokens = true
        let body = try json(openAI.body(for: request(.liveNotes), stream: false, json: nil))
        #expect(body["max_completion_tokens"] as? Int == 100)
        #expect(body["max_tokens"] == nil)
    }

    @Test func jsonModesStepDownFromSchemaToInstructions() throws {
        let request = request(.minutes, schema: replySchema)
        let schema = try json(client.body(for: request, stream: false, json: .schema))
        let format = try #require(schema["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(((format["json_schema"] as? [String: Any])?["strict"]) as? Bool == true)

        let object = try json(client.body(for: request, stream: false, json: .object))
        #expect((object["response_format"] as? [String: String]) == ["type": "json_object"])
        let objectSystem = try #require((object["messages"] as? [[String: String]])?.first?["content"])
        #expect(objectSystem.contains("additionalProperties"), "the schema is spelled out when the server can't enforce it")

        let instructions = try json(client.body(for: request, stream: false, json: .instructions))
        #expect(instructions["response_format"] == nil)
    }

    @Test func streamLinesDecode() {
        #expect(OpenAICompatibleClient.decode(line: #"data: {"choices":[{"delta":{"content":"Hel"}}]}"#) == .text("Hel"))
        #expect(OpenAICompatibleClient.decode(line: #"data:{"choices":[{"delta":{"role":"assistant"}}]}"#) == nil)
        #expect(OpenAICompatibleClient.decode(line: "data: [DONE]") == .done)
        #expect(OpenAICompatibleClient.decode(line: #"data: {"error":{"message":"Rate limited"}}"#) == .error("Rate limited"))
        #expect(OpenAICompatibleClient.decode(line: ": keep-alive") == nil)
    }

    @Test func jsonRepliesAreFoundInsideFences() {
        #expect(JSONReply.object(in: "Sure!\n```json\n{\"ok\": true}\n```") == "{\"ok\": true}")
        #expect(JSONReply.object(in: "no json") == "no json")
    }
}

/// Talks to a stubbed URLSession, never a real server.
@Suite(.serialized)
struct OpenAICompatibleHTTPTests {
    let client = OpenAICompatibleClient(
        providerName: "Groq", baseURL: URL(string: "https://api.groq.com/openai/v1")!,
        apiKey: "gsk_test", fastModel: "fast", smartModel: "smart", session: ProviderStub.session)

    @Test func streamsTextAndSendsTheKey() async throws {
        ProviderStub.respond([(200, """
            data: {"choices":[{"delta":{"role":"assistant"}}]}

            data: {"choices":[{"delta":{"content":"Hello"}}]}

            data: {"choices":[{"delta":{"content":" world"}}]}

            data: [DONE]

            """)])
        var text = ""
        for try await delta in client.stream(request(.liveNotes)) { text += delta }
        #expect(text == "Hello world")
        #expect(ProviderStub.requests.first?.value(forHTTPHeaderField: "authorization") == "Bearer gsk_test")
        #expect(ProviderStub.requests.first?.url?.absoluteString == "https://api.groq.com/openai/v1/chat/completions")
    }

    @Test func completeStreamingJoinsTheStream() async throws {
        ProviderStub.respond([(200, """
            data: {"choices":[{"delta":{"content":"Halo"}}]}

            data: {"choices":[{"delta":{"content":" dunia"}}]}

            data: [DONE]

            """)])
        #expect(try await client.completeStreaming(request(.minutes)) == "Halo dunia")
    }

    @Test func minutesFallBackWhenTheServerRefusesJSONSchemas() async throws {
        ProviderStub.respond([
            (400, #"{"error":{"message":"response_format json_schema is not supported"}}"#),
            (200, #"{"choices":[{"message":{"content":"```json\n{\"ok\": true}\n```"}}]}"#),
        ])
        let text = try await client.complete(request(.minutes, schema: replySchema))
        #expect(JSONReply.object(in: text) == #"{"ok": true}"#)
        let formats = ProviderStub.bodies.map { body in
            ((try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["response_format"] as? [String: Any])?["type"] as? String
        }
        #expect(formats == ["json_schema", "json_object"])
    }

    @Test func streamCutOffByTokenLimitThrowsTruncated() async {
        ProviderStub.respond([(200, """
            data: {"choices":[{"delta":{"content":"{\\"a\\":"},"finish_reason":null}]}

            data: {"choices":[{"delta":{},"finish_reason":"length"}]}

            data: [DONE]

            """)])
        await #expect(throws: OpenAICompatibleClient.Failure.truncated) {
            _ = try await client.completeStreaming(request(.minutes))
        }
        #expect(OpenAICompatibleClient.Failure.truncated.errorDescription == "Jawaban AI terpotong. Coba lagi.")
    }

    @Test func completeCutOffByTokenLimitThrowsTruncated() async {
        ProviderStub.respond([(200, #"{"choices":[{"message":{"content":"{"},"finish_reason":"length"}]}"#)])
        await #expect(throws: OpenAICompatibleClient.Failure.truncated) {
            _ = try await client.complete(request(.minutes))
        }
    }

    @Test func rejectedKeyExplainsWhereToFixIt() async {
        ProviderStub.respond([(401, #"{"error":{"message":"Invalid API Key"}}"#)])
        do {
            _ = try await client.complete(request(.minutes))
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription == "Kunci API Groq ditolak. Periksa di Pengaturan.")
        }
    }

    @Test func listsModels() async throws {
        ProviderStub.respond([(200, #"{"data":[{"id":"model-b"},{"id":"model-a"}]}"#)])
        let models = try await OpenAICompatibleClient.listModels(
            baseURL: URL(string: "http://localhost:11434/v1")!, apiKey: nil, session: ProviderStub.session)
        #expect(models == ["model-a", "model-b"])
        #expect(ProviderStub.requests.first?.url?.absoluteString == "http://localhost:11434/v1/models")
        #expect(ProviderStub.requests.first?.value(forHTTPHeaderField: "authorization") == nil)
    }
}

/// Separate from the Claude tests' stub so the two serialized suites can
/// run side by side.
final class ProviderStub: URLProtocol {
    nonisolated(unsafe) private static var responses: [(Int, Data)] = []
    nonisolated(unsafe) private(set) static var requests: [URLRequest] = []
    nonisolated(unsafe) private(set) static var bodies: [Data] = []

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderStub.self]
        return URLSession(configuration: configuration)
    }()

    /// Responses in order; the last one repeats.
    static func respond(_ responses: [(Int, String)]) {
        self.responses = responses.map { ($0.0, Data($0.1.utf8)) }
        requests = []
        bodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        Self.bodies.append(Self.readBody(of: request))
        let (status, body) = Self.responses.count > 1 ? Self.responses.removeFirst() : Self.responses[0]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands protocols the body as a stream, not `httpBody`.
    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@MainActor
struct AIStoreTests {
    func store() -> AppStore {
        AppStore(
            files: JSONFileStore(directory: FileManager.default.temporaryDirectory.appending(path: "ai-\(UUID().uuidString)")),
            keychainPrefix: "test-\(UUID().uuidString)-")
    }

    @Test func olderSettingsKeepClaude() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"localeIdentifier":"id-ID"}"#.utf8))
        #expect(settings.aiProvider == .anthropic)
        #expect(settings.models(for: .groq).baseURL == "https://api.groq.com/openai/v1")
    }

    @Test func providerModelsSaveUnderReadableKeys() throws {
        var settings = AppSettings()
        settings.providerModels[.groq] = ProviderModels(baseURL: "https://x/v1", fastModel: "f", smartModel: "s")
        let text = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(text.contains(#""groq":"#))
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data(text.utf8)).providerModels == settings.providerModels)
    }

    @Test func aiProblemAsksForKey() {
        let store = store()
        #expect(store.aiProblem == "Isi kunci API Claude di Pengaturan.")
        #expect(!store.isAIReady)
        #expect(store.aiClient() == nil)
    }

    @Test func ollamaNeedsModelsButNoKey() {
        let store = store()
        store.settings.aiProvider = .ollama
        #expect(store.aiProblem == "Pilih model Ollama di Pengaturan.")
        store.settings.providerModels[.ollama] = ProviderModels(
            baseURL: AIProvider.ollama.defaultBaseURL, fastModel: "small", smartModel: "large")
        #expect(store.isAIReady)
        #expect(store.aiClient()?.providerName == "Ollama")
    }

    @Test func customServerNeedsAnAddress() {
        let store = store()
        store.settings.aiProvider = .custom
        #expect(store.aiProblem == "Isi alamat server servermu di Pengaturan.")
    }

    @Test func savedKeyMakesClaudeReady() {
        let store = store()
        store.setAPIKey("  sk-ant-test \n", for: .anthropic)
        defer { store.setAPIKey("", for: .anthropic) }
        #expect(store.apiKey(for: .anthropic) == "sk-ant-test")
        #expect(store.isAIReady)
        #expect(store.aiClient()?.providerName == "Claude")
        store.setAPIKey("", for: .anthropic)
        #expect(store.apiKey(for: .anthropic) == nil)
        #expect(store.aiProblem == "Isi kunci API Claude di Pengaturan.")
    }
}

struct PromptTemplateTests {
    @Test func rendersAndTrims() throws {
        let template = PromptTemplate(name: "t", text: "Hi {{name}}, role: {{ role }}.\n")
        #expect(template.variableNames == ["name", "role"])
        #expect(try template.render(["name": "Agung", "role": "PM", "extra": "x"]) == "Hi Agung, role: PM.")
    }

    @Test func missingVariableThrows() {
        let template = PromptTemplate(name: "t", text: "{{a}} {{b}}")
        #expect(throws: PromptTemplate.Failure.missingVariables(template: "t", names: ["b"])) {
            try template.render(["a": "1"])
        }
    }
}

