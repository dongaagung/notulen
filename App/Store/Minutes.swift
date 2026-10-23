import Foundation

/// The finished minutes, in Indonesian. Text names speakers as tokens
/// ("[[s3]]"); `at`, `start` and `end` are seconds since the meeting began.
/// Decodes from the model's snake_case JSON (`JSONReply.decode`), and from
/// what it saved itself, which `JSONEncoder` writes in camelCase.
struct Minutes: Codable, Equatable, Sendable {
    var titleSuggestion: String
    var summary: String
    var decisions: [Decision]
    var actionItems: [ActionItem]
    var openQuestions: [OpenQuestion]
    var topics: [Topic]
    var speakerNameHints: [NameHint]

    struct Decision: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var text: String
        var at: Double
    }

    struct ActionItem: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var task: String
        var owner: Owner?
        var due: String?
        var at: Double

        struct Owner: Codable, Equatable, Sendable {
            var speaker: SpeakerID?
            var name: String?
        }
    }

    struct OpenQuestion: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var question: String
        var context: String?
        var at: Double
    }

    struct Topic: Codable, Equatable, Sendable {
        var title: String
        var start: Double
        var end: Double
        var points: [String]
    }

    struct NameHint: Codable, Equatable, Sendable {
        var speaker: SpeakerID
        var name: String
        var evidence: String
    }

    init(
        titleSuggestion: String, summary: String, decisions: [Decision] = [], actionItems: [ActionItem] = [],
        openQuestions: [OpenQuestion] = [], topics: [Topic] = [], speakerNameHints: [NameHint] = []
    ) {
        self.titleSuggestion = titleSuggestion
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.topics = topics
        self.speakerNameHints = speakerNameHints
    }

    /// A missing array reads as empty.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        titleSuggestion = try container.decodeIfPresent(String.self, forKey: .titleSuggestion) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        decisions = try container.decodeIfPresent([Decision].self, forKey: .decisions) ?? []
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        openQuestions = try container.decodeIfPresent([OpenQuestion].self, forKey: .openQuestions) ?? []
        topics = try container.decodeIfPresent([Topic].self, forKey: .topics) ?? []
        speakerNameHints = try container.decodeIfPresent([NameHint].self, forKey: .speakerNameHints) ?? []
    }

    /// Times clamped to the meeting, owners and hints naming speakers the
    /// meeting doesn't have dropped (an owner's `name` stays), topics in order.
    func sanitized(duration: TimeInterval, knownSpeakers: Set<SpeakerID>) -> Minutes {
        func clamp(_ time: Double) -> Double { min(max(time, 0), max(duration, 0)) }
        var result = self
        result.decisions = decisions.map { var item = $0; item.at = clamp(item.at); return item }
        result.actionItems = actionItems.map { source in
            var item = source
            item.at = clamp(item.at)
            if let speaker = item.owner?.speaker, !knownSpeakers.contains(speaker) {
                item.owner?.speaker = nil
            }
            return item
        }
        result.openQuestions = openQuestions.map { var item = $0; item.at = clamp(item.at); return item }
        result.topics = topics.map { source in
            var topic = source
            topic.start = clamp(topic.start)
            topic.end = clamp(topic.end)
            return topic
        }.sorted { $0.start < $1.start }
        result.speakerNameHints = speakerNameHints.filter { knownSpeakers.contains($0.speaker) }
        return result
    }
}
