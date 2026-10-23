import Foundation
import Testing
@testable import Notulen

private let meeting = Meeting(
    title: "Weekly Sync", startedAt: Date(timeIntervalSince1970: 1000), endedAt: Date(timeIntervalSince1970: 4600),
    status: .processing, language: "id-ID", audioSource: .systemWide,
    speakers: [SpeakerInfo(id: .remote(1), name: nil)])

private func line(_ speaker: SpeakerID, _ text: String, start: TimeInterval) -> TranscriptLine {
    TranscriptLine(channel: speaker == .me ? .mic : .meeting, speaker: speaker, text: text, start: start, end: start + 2)
}

private func writer(_ client: FakeLLMClient) throws -> MinutesWriter {
    MinutesWriter(client: client, template: try PromptTemplate.load("minutes"))
}

private func fixture() throws -> String {
    let url = try #require(Bundle.module.url(forResource: "minutes", withExtension: "json", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

struct MinutesTests {
    @Test func emptyTranscriptDoesNotCallAI() async throws {
        let fake = FakeLLMClient(reply: "{}")
        let writer = try writer(fake)
        await #expect(throws: MinutesWriter.Failure.nothingRecorded) {
            try await writer.write(meeting: meeting, lines: [])
        }
        #expect(fake.requests.isEmpty)
        #expect(MinutesWriter.Failure.nothingRecorded.errorDescription == "Tidak ada percakapan yang terekam.")
    }

    @Test func linesUnderThreeWordsCountAsNothing() async throws {
        let fake = FakeLLMClient(reply: "{}")
        let writer = try writer(fake)
        let lines = [line(.me, "Halo", start: 1), line(.remote(1), "ya oke", start: 3)]
        await #expect(throws: MinutesWriter.Failure.nothingRecorded) {
            try await writer.write(meeting: meeting, lines: lines)
        }
        #expect(fake.requests.isEmpty)
    }

    /// Japanese and Chinese have no spaces between words.
    @Test func wordsCountWithoutSpaces() async throws {
        #expect(MinutesWriter.wordCount("今日は会議を始めましょう") >= 3)
        #expect(MinutesWriter.wordCount("我们开始开会吧") >= 3)
        #expect(MinutesWriter.wordCount("ya oke") == 2)
        #expect(MinutesWriter.wordCount(" … ?! ") == 0)
        let fake = FakeLLMClient(reply: try fixture())
        _ = try await writer(fake).write(meeting: meeting, lines: [line(.remote(1), "今日は会議を始めましょう", start: 2)])
        #expect(fake.requests.count == 1)
    }

    @Test func requestCarriesTranscriptAndSchema() throws {
        let request = try writer(FakeLLMClient(reply: "{}")).request(
            meeting: meeting, lines: [line(.remote(1), "Selamat pagi semuanya", start: 2)])
        #expect(request.purpose == .minutes)
        #expect(request.maxTokens == 64000)
        #expect(request.jsonSchema == Schemas.minutes)
        #expect(request.messages.count == 1)
        #expect(request.messages[0].content.contains("[00:02] [[s1]]: Selamat pagi semuanya"))
        #expect(request.system.contains("[[me]]"))
        #expect(!request.system.contains("{{"))
    }

    @Test func writeDecodesAndSanitizes() async throws {
        let fake = FakeLLMClient(reply: "```json\n" + (try fixture()) + "\n```")
        let minutes = try await writer(fake).write(
            meeting: meeting, lines: [line(.remote(1), "Selamat pagi semuanya", start: 2)])
        #expect(minutes.actionItems.count == 3)
        // s2 is not a known speaker of this meeting: its owner link and hint go, the name stays.
        #expect(minutes.actionItems[0].owner == .init(speaker: nil, name: "Andi"))
        #expect(minutes.speakerNameHints.isEmpty)
    }

    @Test func sanitizeClampsTimesAndUnknownOwners() {
        let minutes = Minutes(
            titleSuggestion: "T", summary: "S",
            decisions: [.init(id: "d1", text: "x", at: 9999)],
            actionItems: [
                .init(id: "a1", task: "t", owner: .init(speaker: SpeakerID("s9"), name: "Andi"), due: nil, at: -5),
                .init(id: "a2", task: "t", owner: .init(speaker: .me, name: nil), due: nil, at: 10),
            ],
            openQuestions: [.init(id: "q1", question: "?", context: nil, at: 4000)],
            topics: [
                .init(title: "B", start: 2000, end: 9000, points: []),
                .init(title: "A", start: -10, end: 100, points: []),
            ],
            speakerNameHints: [
                .init(speaker: SpeakerID("s9"), name: "Budi", evidence: "e"),
                .init(speaker: .remote(1), name: "Cici", evidence: "e"),
            ])
        let clean = minutes.sanitized(duration: 3600, knownSpeakers: [.me, .remote(1)])
        #expect(clean.decisions[0].at == 3600)
        #expect(clean.actionItems[0].at == 0)
        #expect(clean.actionItems[0].owner == .init(speaker: nil, name: "Andi"))
        #expect(clean.actionItems[1].owner?.speaker == .me)
        #expect(clean.openQuestions[0].at == 3600)
        #expect(clean.topics.map(\.title) == ["A", "B"])
        #expect(clean.topics[0].start == 0)
        #expect(clean.topics[1].end == 3600)
        #expect(clean.speakerNameHints.map(\.name) == ["Cici"])
    }

    @Test func sanitizeMakesActionItemIDsUnique() {
        let item = { (id: String) in Minutes.ActionItem(id: id, task: "t", owner: nil, due: nil, at: 0) }
        let minutes = Minutes(
            titleSuggestion: "T", summary: "S", actionItems: ["a1", "a2", "a2", "a2", "a2-2"].map(item))
        let ids = minutes.sanitized(duration: 10, knownSpeakers: []).actionItems.map(\.id)
        #expect(ids == ["a1", "a2", "a2-2", "a2-3", "a2-2-2"])
        #expect(Set(ids).count == ids.count)
    }

    /// A topic never ends before it starts, also after clamping.
    @Test func sanitizeKeepsTopicEndsAfterStarts() {
        let minutes = Minutes(
            titleSuggestion: "T", summary: "S",
            topics: [
                .init(title: "Backwards", start: 500, end: 100, points: []),
                .init(title: "Past the end", start: 5000, end: 4000, points: []),
                .init(title: "Before the start", start: -50, end: -10, points: []),
            ])
        let clean = minutes.sanitized(duration: 3600, knownSpeakers: [.me])
        #expect(clean.topics.map(\.title) == ["Before the start", "Backwards", "Past the end"])
        #expect(clean.topics.map(\.start) == [0, 500, 3600])
        #expect(clean.topics.map(\.end) == [0, 500, 3600])
    }

    /// Only remote speakers get renamed; the owner is always "Saya".
    @Test func nameHintsAreForRemoteSpeakersOnly() {
        let minutes = Minutes(
            titleSuggestion: "T", summary: "S",
            speakerNameHints: [
                .init(speaker: .me, name: "Agung", evidence: "e"),
                .init(speaker: .others, name: "Budi", evidence: "e"),
                .init(speaker: .remote(1), name: "Cici", evidence: "e"),
            ])
        let clean = minutes.sanitized(duration: 3600, knownSpeakers: [.me, .others, .remote(1)])
        #expect(clean.speakerNameHints.map(\.name) == ["Cici"])
    }

    @Test func decodesFixture() throws {
        let minutes = try JSONReply.decode(Minutes.self, from: try fixture())
        #expect(minutes.actionItems.count == 3)
        #expect(minutes.actionItems[2].owner == nil)
        #expect(minutes.actionItems[2].due == nil)
        #expect(minutes.actionItems[1].owner == .init(speaker: .me, name: nil))
        #expect(minutes.decisions.count == 2)
        #expect(minutes.topics[0].points.count == 2)
        #expect(minutes.speakerNameHints[0].speaker == .remote(2))
        #expect(minutes.titleSuggestion == "Weekly Sync Tim Produk")
    }

    @Test func missingArraysDecodeEmpty() throws {
        let minutes = try JSONReply.decode(
            Minutes.self, from: #"{"title_suggestion":"T","summary":"S","decisions":[],"action_items":[],"topics":[]}"#)
        #expect(minutes.speakerNameHints.isEmpty)
        #expect(minutes.openQuestions.isEmpty)
    }

    @Test func meetingKeepsMinutesAndTranslations() throws {
        var m = meeting
        let minutes = try JSONReply.decode(Minutes.self, from: try fixture())
        m.minutes = minutes
        m.translations = ["en": minutes]
        let back = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(m))
        #expect(back.minutes == minutes)
        #expect(back.translations["en"] == minutes)
    }
}
