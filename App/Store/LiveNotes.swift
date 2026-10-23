import Foundation

/// The running notes per topic during a meeting. The model replies with
/// snake_case keys; `ClaudeClient.decoder` converts them, so no CodingKeys.
struct LiveNotes: Codable, Equatable, Sendable {
    /// Index into `topics` of the topic being discussed now.
    var currentTopic: Int?
    var topics: [Topic]

    struct Topic: Codable, Equatable, Sendable {
        var title: String
        var points: [Point]

        /// "3 poin · 1 keputusan · 1 action item"
        var summary: String {
            var parts = ["\(points.count) poin"]
            let decisions = points.filter { $0.kind == .decision }.count
            let actions = points.filter { $0.kind == .actionItem }.count
            let questions = points.filter { $0.kind == .openQuestion }.count
            if decisions > 0 { parts.append("\(decisions) keputusan") }
            if actions > 0 { parts.append("\(actions) action item") }
            if questions > 0 { parts.append("\(questions) pertanyaan terbuka") }
            return parts.joined(separator: " · ")
        }
    }

    struct Point: Codable, Equatable, Sendable {
        var text: String
        var kind: Kind
    }

    enum Kind: String, Codable, Sendable {
        case point, decision
        case actionItem = "action_item"
        case openQuestion = "open_question"
    }
}
