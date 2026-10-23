import Foundation

/// Translates finished minutes into another language with the smart model.
/// The reply is trusted only when it keeps the minutes' structure: the same
/// items, IDs, times, owners and speaker tokens.
struct Translator: Sendable {
    enum Failure: LocalizedError, Equatable {
        case structureChanged

        var errorDescription: String? {
            switch self {
            case .structureChanged: "Terjemahan tidak cocok dengan notulen aslinya. Coba lagi."
            }
        }
    }

    let client: any LLMClient
    let template: PromptTemplate

    init(client: any LLMClient, template: PromptTemplate) {
        self.client = client
        self.template = template
    }

    /// Whether `code` looks like a BCP 47 language tag ("en", "zh-Hans").
    /// Indonesian is the original, never a translation.
    static func isValidLanguageCode(_ code: String) -> Bool {
        guard code.wholeMatch(of: /[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*/) != nil else { return false }
        return !isIndonesian(code)
    }

    static func isIndonesian(_ code: String) -> Bool {
        let lower = code.lowercased()
        return lower == "id" || lower.hasPrefix("id-")
    }

    /// "EN" -> "en", "zh-hans" -> "zh-Hans", so one language has one key.
    static func normalized(_ code: String) -> String {
        let parts = code.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-").map(String.init)
        guard let first = parts.first else { return code }
        let rest = parts.dropFirst().map { part -> String in
            if part.count == 4, part.allSatisfy(\.isLetter) { return part.prefix(1).uppercased() + part.dropFirst().lowercased() }
            if part.count == 2, part.allSatisfy(\.isLetter) { return part.uppercased() }
            return part.lowercased()
        }
        return ([first.lowercased()] + rest).joined(separator: "-")
    }

    /// The language's name in Indonesian ("Inggris"), nil when not recognised.
    static func languageName(_ code: String) -> String? {
        guard isValidLanguageCode(code) else { return nil }
        let locale = Locale(identifier: "id_ID")
        guard let name = locale.localizedString(forIdentifier: code), name.lowercased() != code.lowercased() else {
            return nil
        }
        return name
    }

    func request(_ minutes: Minutes, to language: String) throws -> LLMRequest {
        let language = Self.normalized(language)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = String(decoding: try encoder.encode(minutes), as: UTF8.self)
        return LLMRequest(
            purpose: .translation, system: try template.render(["language": language]),
            messages: [ChatMessage(role: .user, content: "Bahasa tujuan (BCP 47): \(language)\n\n\(body)")],
            maxTokens: 64000, jsonSchema: Schemas.minutes)
    }

    /// Not sanitized: the source already was, and a reply that differs in
    /// structure is rejected rather than repaired.
    func translate(_ minutes: Minutes, to language: String) async throws -> Minutes {
        let reply = try await client.completeStreaming(try request(minutes, to: language))
        let result = try JSONReply.decode(Minutes.self, from: reply)
        guard result.hasSameStructure(as: minutes) else { throw Failure.structureChanged }
        return result
    }
}

extension Minutes {
    /// Same items in the same order, with the same IDs, times, owner
    /// speakers and speaker tokens; only the words may differ.
    func hasSameStructure(as other: Minutes) -> Bool {
        func tokens(_ text: String?) -> [String] {
            (text ?? "").matches(of: /\[\[[^\]]*\]\]/).map { String($0.output) }.sorted()
        }
        func same(_ a: String?, _ b: String?) -> Bool { tokens(a) == tokens(b) }

        guard decisions.count == other.decisions.count, actionItems.count == other.actionItems.count,
              openQuestions.count == other.openQuestions.count, topics.count == other.topics.count,
              speakerNameHints.count == other.speakerNameHints.count,
              same(titleSuggestion, other.titleSuggestion), same(summary, other.summary)
        else { return false }
        for (a, b) in zip(decisions, other.decisions) {
            guard a.id == b.id, a.at == b.at, same(a.text, b.text) else { return false }
        }
        for (a, b) in zip(actionItems, other.actionItems) {
            guard a.id == b.id, a.at == b.at, a.owner?.speaker == b.owner?.speaker,
                  (a.owner == nil) == (b.owner == nil), same(a.task, b.task), same(a.due, b.due)
            else { return false }
        }
        for (a, b) in zip(openQuestions, other.openQuestions) {
            guard a.id == b.id, a.at == b.at, same(a.question, b.question), same(a.context, b.context) else { return false }
        }
        for (a, b) in zip(topics, other.topics) {
            guard a.start == b.start, a.end == b.end, a.points.count == b.points.count, same(a.title, b.title),
                  zip(a.points, b.points).allSatisfy({ same($0, $1) })
            else { return false }
        }
        for (a, b) in zip(speakerNameHints, other.speakerNameHints) {
            guard a.speaker == b.speaker, same(a.evidence, b.evidence) else { return false }
        }
        return true
    }
}
