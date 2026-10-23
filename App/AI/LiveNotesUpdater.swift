import Foundation
import Observation

/// Keeps the meeting's live notes current: every `interval` seconds the fast
/// model gets the previous notes plus only the lines said since, and replies
/// with the updated notes. One request at a time; lines that arrive during
/// one wait for the next.
@MainActor
@Observable
final class LiveNotesUpdater {
    static let interval: TimeInterval = 150
    /// This many pending lines make an update due before `interval`.
    static let earlyLineCount = 40
    /// The most lines one request carries, oldest first; the rest wait.
    static let maxLinesPerRequest = 200

    private(set) var notes: LiveNotes?
    private(set) var updatedAt: Date?
    /// The last update failed for lack of internet. The lines wait.
    private(set) var isDelayed = false
    /// Final lines the model hasn't seen yet.
    private(set) var pendingLines: [TranscriptLine] = []

    /// A successful update, to save with the meeting.
    @ObservationIgnored var onUpdate: ((LiveNotes, Date) -> Void)?
    /// A failure other than missing internet, as a message for the owner.
    @ObservationIgnored var onError: ((String) -> Void)?

    @ObservationIgnored private let client: any LLMClient
    @ObservationIgnored private let template: PromptTemplate
    @ObservationIgnored private let meeting: () -> Meeting
    @ObservationIgnored private var lastAttempt: Date
    /// After a failure the early trigger waits out the normal interval.
    @ObservationIgnored private var lastSucceeded = true
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var stopped = false

    /// `start`: when the first interval begins. Notes of a resumed meeting
    /// carry on from what it saved.
    init(
        client: any LLMClient, template: PromptTemplate, meeting: @escaping () -> Meeting, start: Date = Date()
    ) {
        self.client = client
        self.template = template
        self.meeting = meeting
        self.lastAttempt = start
        let current = meeting()
        notes = current.liveNotes
        updatedAt = current.liveNotesUpdatedAt
    }

    func add(_ line: TranscriptLine) {
        guard !stopped else { return }
        pendingLines.append(line)
    }

    /// No further requests, and a reply still on its way is dropped.
    func stop() {
        stopped = true
    }

    func updateIfDue(now: Date) async {
        guard !stopped, !inFlight, !pendingLines.isEmpty else { return }
        let due = now.timeIntervalSince(lastAttempt) >= Self.interval
            || (lastSucceeded && pendingLines.count >= Self.earlyLineCount)
        guard due else { return }
        lastAttempt = now
        lastSucceeded = false
        inFlight = true
        defer { inFlight = false }

        let sent = Array(pendingLines.prefix(Self.maxLinesPerRequest))
        do {
            let reply = try await client.complete(try request(for: sent))
            guard !stopped else { return }
            var updated = try JSONReply.decode(LiveNotes.self, from: reply)
            if let current = updated.currentTopic, !updated.topics.indices.contains(current) {
                updated.currentTopic = nil
            }
            notes = updated
            updatedAt = now
            pendingLines.removeFirst(min(sent.count, pendingLines.count))
            isDelayed = false
            lastSucceeded = true
            onUpdate?(updated, now)
        } catch is URLError {
            guard !stopped else { return }
            isDelayed = true
        } catch {
            guard !stopped else { return }
            isDelayed = false
            onError?(error.localizedDescription)
        }
    }

    func request(for lines: [TranscriptLine]) throws -> LLMRequest {
        let system = try template.render(["language": meeting().language])
        let previous = notes.flatMap { try? Self.encoder.encode($0) }
            .map { String(decoding: $0, as: UTF8.self) } ?? "belum ada"
        let spoken = lines.map {
            "[\(MeetingTime.format($0.start))] \($0.speaker == .me ? "Saya" : "Lainnya"): \($0.text)"
        }
        let content = "Catatan sebelumnya:\n\(previous)\n\nPercakapan baru:\n" + spoken.joined(separator: "\n")
        return LLMRequest(
            purpose: .liveNotes, system: system, messages: [ChatMessage(role: .user, content: content)],
            maxTokens: 4000, jsonSchema: Schemas.liveNotes)
    }

    /// The previous notes in the same snake_case the model replies with.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
