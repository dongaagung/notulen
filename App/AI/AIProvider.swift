import Foundation

/// Where live notes, minutes and translation come from. Exactly
/// one is active at a time.
enum AIProvider: String, Codable, CaseIterable, Identifiable, CodingKeyRepresentable, Sendable {
    case anthropic
    case openAI
    case gemini
    case deepSeek
    case groq
    case openRouter
    case ollama
    case custom

    var id: Self { self }

    var label: String {
        switch self {
        case .anthropic: "Anthropic (Claude)"
        case .openAI: "OpenAI"
        case .gemini: "Google Gemini"
        case .deepSeek: "DeepSeek"
        case .groq: "Groq"
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama (di Mac ini)"
        case .custom: "Server lain yang kompatibel dengan OpenAI"
        }
    }

    /// Short name for messages.
    var shortName: String {
        switch self {
        case .anthropic: "Claude"
        case .custom: "servermu"
        case .ollama: "Ollama"
        default: label
        }
    }

    /// Every provider but Anthropic speaks the OpenAI chat-completions API
    /// at this address. Empty for a custom server, which the user fills in.
    var defaultBaseURL: String {
        switch self {
        case .anthropic: ""
        case .openAI: "https://api.openai.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepSeek: "https://api.deepseek.com/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .ollama: "http://localhost:11434/v1"
        case .custom: ""
        }
    }

    /// A local Ollama, and some custom servers, run without a key.
    var requiresAPIKey: Bool {
        self != .ollama && self != .custom
    }

    /// The key is used if there is one.
    var acceptsAPIKey: Bool { self != .ollama }

    /// Keychain account for this provider's key.
    var keychainAccount: String {
        self == .anthropic ? Keychain.apiKeyAccount : "\(rawValue)-api-key"
    }

    /// OpenAI's newer models reject `max_tokens` in favor of this.
    var usesMaxCompletionTokens: Bool { self == .openAI }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openAI, .deepSeek, .openRouter: "sk-…"
        case .gemini: "AIza…"
        case .groq: "gsk_…"
        case .ollama, .custom: "Opsional"
        }
    }
}

/// Server address and models for an OpenAI-compatible provider.
struct ProviderModels: Codable, Equatable, Sendable {
    var baseURL = ""
    /// Live notes.
    var fastModel = ""
    /// Minutes and translation.
    var smartModel = ""
}
