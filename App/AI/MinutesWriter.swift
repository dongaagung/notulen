import Foundation

/// Writes the meeting's minutes: the whole transcript goes to the smart
/// model in one request, and the structured reply is checked against the
/// meeting before it's trusted.
struct MinutesWriter: Sendable {
    enum Failure: LocalizedError, Equatable {
        case nothingRecorded

        var errorDescription: String? {
            switch self {
            case .nothingRecorded: "Tidak ada percakapan yang terekam."
            }
        }
    }

    /// A line needs this many words to count as speech.
    static let minimumWords = 3

    let client: any LLMClient
    let template: PromptTemplate

    init(client: any LLMClient, template: PromptTemplate) {
        self.client = client
        self.template = template
    }

    func request(meeting: Meeting, lines: [TranscriptLine]) throws -> LLMRequest {
        LLMRequest(
            purpose: .minutes, system: try template.render([:]),
            messages: [ChatMessage(role: .user, content: TranscriptFormatter.aiTranscript(lines: lines, meeting: meeting))],
            maxTokens: 64000, jsonSchema: Schemas.minutes)
    }

    func write(meeting: Meeting, lines: [TranscriptLine]) async throws -> Minutes {
        guard lines.contains(where: { $0.text.split(whereSeparator: \.isWhitespace).count >= Self.minimumWords }) else {
            throw Failure.nothingRecorded
        }
        let reply = try await client.completeStreaming(try request(meeting: meeting, lines: lines))
        let minutes = try JSONReply.decode(Minutes.self, from: reply)
        let duration = meeting.endedAt.map { $0.timeIntervalSince(meeting.startedAt) } ?? meeting.recordedUntil(lines)
        var known: Set<SpeakerID> = [.me]
        known.formUnion(meeting.speakers.map(\.id))
        known.formUnion(lines.map { meeting.speaker(of: $0) })
        known.remove(.others)
        return minutes.sanitized(duration: duration, knownSpeakers: known)
    }
}
