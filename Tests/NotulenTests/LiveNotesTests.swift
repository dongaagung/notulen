import Foundation
import Testing
@testable import Notulen

private func notesJSON(_ title: String) -> String {
    """
    {"current_topic":0,"topics":[{"title":"\(title)","points":[{"text":"x","kind":"point"}]}]}
    """
}

private func line(_ text: String, at start: TimeInterval = 0, speaker: SpeakerID = .others) -> TranscriptLine {
    TranscriptLine(channel: speaker == .me ? .mic : .meeting, speaker: speaker, text: text, start: start, end: start + 1)
}

@MainActor
private func makeUpdater(_ client: FakeLLMClient, start: Date) throws -> LiveNotesUpdater {
    let meeting = Meeting(
        title: "T", startedAt: start, status: .recording, language: "id-ID", audioSource: .systemWide)
    return LiveNotesUpdater(
        client: client, template: try PromptTemplate.load("live_notes"), meeting: { meeting }, start: start)
}

struct LiveNotesModelTests {
    @Test func topicSummary() {
        let topic = LiveNotes.Topic(title: "T", points: [
            .init(text: "a", kind: .point), .init(text: "b", kind: .decision), .init(text: "c", kind: .actionItem),
        ])
        #expect(topic.summary == "3 poin · 1 keputusan · 1 action item")
        #expect(LiveNotes.Topic(title: "T", points: [.init(text: "a", kind: .point)]).summary == "1 poin")
    }

    @Test func liveNotesDecodeSnakeCase() throws {
        let json = #"{"current_topic":1,"topics":[{"title":"T","points":[{"text":"x","kind":"action_item"}]}]}"#
        let notes = try JSONReply.decode(LiveNotes.self, from: json)
        #expect(notes.currentTopic == 1)
        #expect(notes.topics[0].points[0].kind == .actionItem)
    }
}

@MainActor
struct LiveNotesTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func requestSendsPreviousNotesAndOnlyNewLines() async throws {
        let client = FakeLLMClient(reply: notesJSON("Rilis v2.3"))
        let updater = try makeUpdater(client, start: t0)
        updater.add(line("alpha satu"))
        updater.add(line("beta dua", at: 5, speaker: .me))
        await updater.updateIfDue(now: t0.addingTimeInterval(150))
        #expect(updater.notes?.topics.first?.title == "Rilis v2.3")
        #expect(updater.pendingLines.isEmpty)
        updater.add(line("gamma tiga", at: 70))
        let content = try updater.request(for: updater.pendingLines).messages[0].content
        #expect(content.contains("Rilis v2.3"))
        #expect(content.contains("[01:10] Lainnya: gamma tiga"))
        #expect(!content.contains("alpha satu"))
        let first = client.requests[0]
        #expect(first.messages[0].content.contains("belum ada"))
        #expect(first.messages[0].content.contains("[00:05] Saya: beta dua"))
        #expect(first.purpose == .liveNotes)
        #expect(first.maxTokens == 4000)
        #expect(first.jsonSchema == Schemas.liveNotes)
        #expect(first.system.contains("id-ID"))
    }

    @Test func failedUpdateKeepsLinesPending() async throws {
        let client = FakeLLMClient(replies: [.failure(URLError(.notConnectedToInternet)), .success(notesJSON("A"))])
        let updater = try makeUpdater(client, start: t0)
        var errors: [String] = []
        updater.onError = { errors.append($0) }
        updater.add(line("a"))
        updater.add(line("b"))
        await updater.updateIfDue(now: t0.addingTimeInterval(150))
        #expect(updater.isDelayed)
        #expect(updater.pendingLines.count == 2)
        #expect(errors.isEmpty)
        await updater.updateIfDue(now: t0.addingTimeInterval(300))
        #expect(!updater.isDelayed)
        #expect(updater.pendingLines.isEmpty)
    }

    @Test func otherErrorsAreReported() async throws {
        let client = FakeLLMClient(replies: [.failure(ClaudeClient.Failure.refusal)])
        let updater = try makeUpdater(client, start: t0)
        var errors: [String] = []
        updater.onError = { errors.append($0) }
        updater.add(line("a"))
        await updater.updateIfDue(now: t0.addingTimeInterval(150))
        #expect(errors == [ClaudeClient.Failure.refusal.localizedDescription])
        #expect(!updater.isDelayed)
        #expect(updater.pendingLines.count == 1)
    }

    @Test func notDueBeforeInterval() async throws {
        let client = FakeLLMClient(reply: notesJSON("A"))
        let updater = try makeUpdater(client, start: t0)
        updater.add(line("a"))
        await updater.updateIfDue(now: t0.addingTimeInterval(149))
        #expect(client.requests.isEmpty)
        await updater.updateIfDue(now: t0.addingTimeInterval(150))
        #expect(client.requests.count == 1)
    }

    @Test func nothingPendingNeverRequests() async throws {
        let client = FakeLLMClient(reply: notesJSON("A"))
        let updater = try makeUpdater(client, start: t0)
        await updater.updateIfDue(now: t0.addingTimeInterval(1000))
        #expect(client.requests.isEmpty)
    }

    @Test func earlyUpdateAfterManyLines() async throws {
        let client = FakeLLMClient(reply: notesJSON("A"))
        let updater = try makeUpdater(client, start: t0)
        for index in 0..<LiveNotesUpdater.earlyLineCount { updater.add(line("l\(index)")) }
        await updater.updateIfDue(now: t0.addingTimeInterval(10))
        #expect(client.requests.count == 1)
    }

    @Test func stoppedUpdaterSendsNothing() async throws {
        let client = FakeLLMClient(reply: notesJSON("A"))
        let updater = try makeUpdater(client, start: t0)
        updater.add(line("a"))
        updater.stop()
        await updater.updateIfDue(now: t0.addingTimeInterval(500))
        #expect(client.requests.isEmpty)
    }

    @Test func outOfRangeCurrentTopicIsDropped() async throws {
        let client = FakeLLMClient(reply: #"{"current_topic":5,"topics":[{"title":"A","points":[]}]}"#)
        let updater = try makeUpdater(client, start: t0)
        updater.add(line("a"))
        await updater.updateIfDue(now: t0.addingTimeInterval(150))
        #expect(updater.notes?.currentTopic == nil)
    }
}

/// Holds each request until the test lets it answer.
private final class GatedLLMClient: LLMClient, @unchecked Sendable {
    let providerName = "Gated"
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<String, Never>] = []
    private var recorded: [LLMRequest] = []
    var requests: [LLMRequest] { lock.withLock { recorded } }
    var waitingCount: Int { lock.withLock { waiting.count } }

    func complete(_ request: LLMRequest) async throws -> String {
        await withCheckedContinuation { continuation in
            lock.withLock {
                recorded.append(request)
                waiting.append(continuation)
            }
        }
    }

    func release(_ reply: String) {
        let next = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
        next?.resume(returning: reply)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
struct LiveNotesBackoffTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func fill(_ updater: LiveNotesUpdater, _ count: Int) {
        for index in 0..<count { updater.add(line("l\(index)", at: TimeInterval(index))) }
    }

    @Test func failureWithManyPendingWaitsForTheInterval() async throws {
        let client = FakeLLMClient(replies: [.failure(URLError(.notConnectedToInternet)), .success(notesJSON("A"))])
        let updater = try makeUpdater(client, start: t0)
        fill(updater, 45)
        await updater.updateIfDue(now: t0.addingTimeInterval(10))
        #expect(client.requests.count == 1)
        await updater.updateIfDue(now: t0.addingTimeInterval(20))
        #expect(client.requests.count == 1)
        await updater.updateIfDue(now: t0.addingTimeInterval(159))
        #expect(client.requests.count == 1)
        await updater.updateIfDue(now: t0.addingTimeInterval(160))
        #expect(client.requests.count == 2)
    }

    @Test func persistentErrorDoesNotRepeatEveryTick() async throws {
        let client = FakeLLMClient(replies: [.failure(ClaudeClient.Failure.refusal)])
        let updater = try makeUpdater(client, start: t0)
        var errors = 0
        updater.onError = { _ in errors += 1 }
        fill(updater, 45)
        for tick in 1...10 { await updater.updateIfDue(now: t0.addingTimeInterval(TimeInterval(tick * 10))) }
        #expect(client.requests.count == 1 && errors == 1)
    }

    @Test func requestsCarryAtMostTheCapOldestFirst() async throws {
        let client = FakeLLMClient(reply: notesJSON("A"))
        let updater = try makeUpdater(client, start: t0)
        fill(updater, 450)
        await updater.updateIfDue(now: t0.addingTimeInterval(150))
        let content = client.requests[0].messages[0].content
        #expect(content.components(separatedBy: "\n").filter { $0.contains("] Lainnya: l") }.count == 200)
        #expect(content.contains("Lainnya: l199") && !content.contains("Lainnya: l200"))
        #expect(updater.pendingLines.count == 250)
        // The last attempt succeeded, so the early trigger applies again.
        await updater.updateIfDue(now: t0.addingTimeInterval(160))
        #expect(client.requests.count == 2)
    }

    @Test func otherErrorClearsDelayed() async throws {
        let client = FakeLLMClient(replies: [
            .failure(URLError(.notConnectedToInternet)), .failure(ClaudeClient.Failure.refusal),
        ])
        let updater = try makeUpdater(client, start: t0)
        updater.add(line("a"))
        await updater.updateIfDue(now: t0.addingTimeInterval(150))
        #expect(updater.isDelayed)
        await updater.updateIfDue(now: t0.addingTimeInterval(300))
        #expect(!updater.isDelayed)
    }

    @Test func replyAfterStopChangesNothing() async throws {
        let client = GatedLLMClient()
        let updater = try makeUpdater2(client)
        var updates = 0
        updater.onUpdate = { _, _ in updates += 1 }
        updater.add(line("a"))
        let task = Task { await updater.updateIfDue(now: t0.addingTimeInterval(150)) }
        #expect(await waitUntil { client.waitingCount == 1 })
        updater.stop()
        client.release(notesJSON("Late"))
        await task.value
        #expect(updater.notes == nil && updates == 0)
    }

    @Test func linesDuringARequestGoInTheNextOne() async throws {
        let client = GatedLLMClient()
        let updater = try makeUpdater2(client)
        updater.add(line("first"))
        let task = Task { await updater.updateIfDue(now: t0.addingTimeInterval(150)) }
        #expect(await waitUntil { client.waitingCount == 1 })
        updater.add(line("second"))
        client.release(notesJSON("A"))
        await task.value
        #expect(updater.pendingLines.map(\.text) == ["second"])
        let next = Task { await updater.updateIfDue(now: t0.addingTimeInterval(300)) }
        #expect(await waitUntil { client.waitingCount == 1 })
        client.release(notesJSON("B"))
        await next.value
        let first = client.requests[0].messages[0].content
        let second = client.requests[1].messages[0].content
        #expect(first.contains("first") && !first.contains("second"))
        #expect(second.contains("second") && !second.contains("Lainnya: first"))
        #expect(updater.pendingLines.isEmpty)
    }

    private func makeUpdater2(_ client: some LLMClient) throws -> LiveNotesUpdater {
        let meeting = Meeting(
            title: "T", startedAt: t0, status: .recording, language: "id-ID", audioSource: .systemWide)
        return LiveNotesUpdater(
            client: client, template: try PromptTemplate.load("live_notes"), meeting: { meeting }, start: t0)
    }
}
