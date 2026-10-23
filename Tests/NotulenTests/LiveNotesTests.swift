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
