import Foundation

/// Where the meeting's voices come from.
enum MeetingAudioSource: Codable, Hashable, Sendable {
    /// Everything the Mac plays. Works with any meeting app or browser tab.
    case systemWide
    /// Only one app (and its helper processes), identified by its bundle ID.
    case app(bundleID: String, name: String)

    var label: String {
        switch self {
        case .systemWide: "Semua audio sistem"
        case .app(_, let name): name
        }
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var meetingAudio: MeetingAudioSource = .systemWide
    /// Speech recognition locale for both channels, as a BCP 47 identifier.
    var localeIdentifier = "id-ID"
    /// Terms to recognize on top of the built-in ones.
    var vocabulary: [String] = []
    /// Multiplier for notes, transcript and minutes text. See `TextScale`.
    var textScale = TextScale.standard
    /// The one provider all AI features use.
    var aiProvider = AIProvider.anthropic
    /// Server address and models per OpenAI-compatible provider, kept when
    /// switching so switching back needs no re-entry.
    var providerModels: [AIProvider: ProviderModels] = [:]
    /// Notion page that new minutes pages are created under.
    var notionParentPageID: String?
}

extension AppSettings {
    /// The provider's address and models, with its default address filled in
    /// before the user changes it.
    func models(for provider: AIProvider) -> ProviderModels {
        providerModels[provider] ?? ProviderModels(baseURL: provider.defaultBaseURL)
    }

    /// Fields missing from an older settings.json keep their defaults.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        meetingAudio = try container.decodeIfPresent(MeetingAudioSource.self, forKey: .meetingAudio) ?? defaults.meetingAudio
        localeIdentifier = try container.decodeIfPresent(String.self, forKey: .localeIdentifier) ?? defaults.localeIdentifier
        vocabulary = try container.decodeIfPresent([String].self, forKey: .vocabulary) ?? defaults.vocabulary
        textScale = try container.decodeIfPresent(Double.self, forKey: .textScale) ?? defaults.textScale
        aiProvider = try container.decodeIfPresent(AIProvider.self, forKey: .aiProvider) ?? defaults.aiProvider
        providerModels = try container.decodeIfPresent([AIProvider: ProviderModels].self, forKey: .providerModels)
            ?? defaults.providerModels
        notionParentPageID = try container.decodeIfPresent(String.self, forKey: .notionParentPageID)
    }
}
