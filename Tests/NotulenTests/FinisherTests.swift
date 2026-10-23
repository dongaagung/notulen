import AVFoundation
import Foundation
import Testing
@testable import Notulen

@MainActor
final class FinisherTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "NotulenTests-\(UUID().uuidString)")
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) lazy var store = makeStore()

    deinit { try? FileManager.default.removeItem(at: root) }

    private func makeStore() -> AppStore {
        AppStore(files: JSONFileStore(directory: root), keychainPrefix: "test-\(UUID().uuidString)-")
    }

    private func fixture() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "minutes", withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Writes with `client`; nil stands for an AI provider that isn't ready.
    private func makeFinisher(_ client: (any LLMClient)?) throws -> MeetingFinisher {
        let template = try PromptTemplate.load("minutes")
        return MeetingFinisher(store: store) { client.map { MinutesWriter(client: $0, template: template) } }
    }

    /// An hour-long meeting saved as `status`, with `lines` in its journal.
    private func savedMeeting(
        title: String = "", status: MeetingStatus = .processing, lines: [String]
    ) throws -> Meeting {
        let meeting = Meeting(
            title: title, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(3600), status: status,
            language: "id-ID", audioSource: .systemWide)
        store.save(meeting)
        let journal = try TranscriptJournal(url: #require(store.transcriptURL(for: meeting.id)))
        for (index, text) in lines.enumerated() {
            try journal.append(TranscriptLine(
                channel: .meeting, speaker: .others, text: text, start: Double(index) * 10, end: Double(index) * 10 + 5))
        }
        journal.close()
        return meeting
    }

    /// As saved on disk.
    private func saved(_ id: UUID) throws -> Meeting {
        try #require(makeStore().meetings.first { $0.id == id })
    }

    private static let speech = ["Selamat pagi semuanya, kita mulai", "Rilis versi baru diundur seminggu"]

    // MARK: Finish

    @Test func finishWritesMinutesAndMarksReady() async throws {
        let fake = FakeLLMClient(reply: try fixture())
        let meeting = try savedMeeting(lines: Self.speech)
        let finisher = try makeFinisher(fake)
        await finisher.finish(meeting.id, audio: nil)

        let finished = try saved(meeting.id)
        #expect(finished.status == .ready)
        #expect(finished.minutes != nil)
        #expect(finished.failure == nil)
        #expect(finished.title == "Weekly Sync Tim Produk")
        #expect(store.meetings.first { $0.id == meeting.id } == finished)
        #expect(fake.requests.count == 1)
        #expect(finisher.running.isEmpty)
    }

    @Test func finishKeepsTheOwnersTitle() async throws {
        let meeting = try savedMeeting(title: "Rapat Mingguan", lines: Self.speech)
        try await makeFinisher(FakeLLMClient(reply: try fixture())).finish(meeting.id, audio: nil)
        #expect(try saved(meeting.id).title == "Rapat Mingguan")
    }

    @Test func finishFailureKeepsTranscript() async throws {
        let fake = FakeLLMClient(replies: [.failure(URLError(.notConnectedToInternet))])
        let meeting = try savedMeeting(lines: Self.speech)
        try await makeFinisher(fake).finish(meeting.id, audio: nil)

        let failed = try saved(meeting.id)
        #expect(failed.status == .failed)
        #expect(failed.failure == URLError(.notConnectedToInternet).localizedDescription)
        #expect(failed.minutes == nil)
        #expect(try store.transcriptLines(for: meeting.id).map(\.text) == Self.speech)
    }

    @Test func emptyMeetingEndsReadyWithoutMinutes() async throws {
        let fake = FakeLLMClient(reply: try fixture())
        let meeting = try savedMeeting(lines: [])
        try await makeFinisher(fake).finish(meeting.id, audio: nil)

        let finished = try saved(meeting.id)
        #expect(finished.status == .ready)
        #expect(finished.minutes == nil)
        #expect(finished.failure == nil)
        #expect(fake.requests.isEmpty)
    }

    /// Nothing was said, so there's nothing the AI is needed for.
    @Test func emptyMeetingNeedsNoAI() async throws {
        let meeting = try savedMeeting(lines: ["Halo", "ya oke"])
        try await makeFinisher(nil).finish(meeting.id, audio: nil)
        #expect(try saved(meeting.id).status == .ready)
    }

    @Test func finishWithoutAIFailsWithTheProblem() async throws {
        let meeting = try savedMeeting(lines: Self.speech)
        let problem = try #require(store.aiProblem)
        try await makeFinisher(nil).finish(meeting.id, audio: nil)

        let failed = try saved(meeting.id)
        #expect(failed.status == .failed)
        #expect(failed.failure == problem)
    }

    @Test func finishWipesAudio() async throws {
        let buffer = MeetingAudioBuffer()
        var converter = AudioConverter(target: .mono16kInt16)
        buffer.append(try converter.convert(AudioChunk.audible(channels: 2).buffer))
        try #require(buffer.sampleCount > 0)
        let meeting = try savedMeeting(lines: Self.speech)
        // Also when the minutes fail.
        try await makeFinisher(nil).finish(meeting.id, audio: buffer)
        #expect(buffer.sampleCount == 0)
    }

    /// The sidebar and the detail show the step while the minutes are written.
    @Test func runningShowsTheStep() async throws {
        let gate = HeldLLMClient(reply: try fixture())
        let meeting = try savedMeeting(lines: Self.speech)
        let finisher = try makeFinisher(gate)
        let finishing = Task { await finisher.finish(meeting.id, audio: nil) }
        #expect(await waitUntil { gate.isWaiting })
        #expect(finisher.running == [meeting.id: .writingMinutes])
        #expect(store.meetings.first { $0.id == meeting.id }?.status == .processing)
        gate.release()
        await finishing.value
        #expect(finisher.running.isEmpty)
        #expect(try saved(meeting.id).status == .ready)
    }

    /// The owner may rename or retitle while the minutes are written.
    @Test func finishKeepsChangesMadeMeanwhile() async throws {
        let gate = HeldLLMClient(reply: try fixture())
        let meeting = try savedMeeting(lines: Self.speech)
        let finisher = try makeFinisher(gate)
        let finishing = Task { await finisher.finish(meeting.id, audio: nil) }
        #expect(await waitUntil { gate.isWaiting })
        var edited = try #require(store.meetings.first { $0.id == meeting.id })
        edited.title = "Judul baru"
        store.save(edited)
        gate.release()
        await finishing.value
        #expect(try saved(meeting.id).title == "Judul baru")
    }

    // MARK: Regenerate

    @Test func regenerateClearsChecksAndTranslations() async throws {
        var meeting = try savedMeeting(title: "Weekly", status: .ready, lines: Self.speech)
        let old = Minutes(titleSuggestion: "Lama", summary: "Ringkasan lama")
        meeting.minutes = old
        meeting.actionItemsDone = ["a1", "a2"]
        meeting.translations = ["en": old]
        meeting.notionPageID = "page"
        store.save(meeting)
        let fake = FakeLLMClient(reply: try fixture())
        try await makeFinisher(fake).regenerate(meeting.id)

        let again = try saved(meeting.id)
        #expect(again.status == .ready)
        #expect(again.actionItemsDone.isEmpty)
        #expect(again.translations.isEmpty)
        #expect(again.minutes?.summary.hasPrefix("Tim membahas") == true)
        #expect(again.title == "Weekly")
        // The Notion page is updated next time, not lost.
        #expect(again.notionPageID == "page")
        #expect(fake.requests.count == 1)
    }

    // MARK: Session

    @Test func stopHandsTheMeetingToTheFinisher() async throws {
        let meetingCapture = FakeCapture.meeting()
        let buffer = MeetingAudioBuffer()
        let fake = FakeLLMClient(reply: try fixture())
        let session = MeetingSession(
            store: store, finisher: try makeFinisher(fake),
            devices: { _ in CaptureDevices(meeting: meetingCapture, mic: FakeCapture.mic(), output: FakeOutputRoute()) },
            speech: { _, _ in FakeSpeech(meeting: [.final("Selamat pagi semuanya, kita mulai", 1, 3)]) },
            now: { [startedAt] in startedAt }, audioBuffer: { buffer }, power: .fake())
        try session.begin(.init(
            title: "", audioSource: .systemWide, locale: Locale(identifier: "id-ID"), vocabulary: []))
        #expect(await waitUntil { session.phase == .recording })
        meetingCapture.send()
        #expect(await waitUntil { session.transcript.lines.count == 1 && buffer.sampleCount > 0 })
        let stopped = try #require(await session.stop())

        #expect(stopped.status == .ready)
        #expect(stopped.minutes != nil)
        #expect(stopped.title == "Weekly Sync Tim Produk")
        #expect(try saved(stopped.id) == stopped)
        #expect(fake.requests.count == 1)
        #expect(buffer.sampleCount == 0)
        #expect(session.phase == .idle)
    }

    @Test func finishingAnInterruptedMeetingWritesItsMinutes() async throws {
        let meeting = try savedMeeting(status: .interrupted, lines: Self.speech)
        let session = MeetingSession(
            store: store, finisher: try makeFinisher(FakeLLMClient(reply: try fixture())), power: .fake())
        await session.finishInterrupted(meeting)

        let finished = try saved(meeting.id)
        #expect(finished.status == .ready)
        #expect(finished.minutes != nil)
        #expect(finished.endedAt == startedAt.addingTimeInterval(15))
    }

    // MARK: Launch

    /// Quitting while the minutes were written leaves the meeting failed, so
    /// Coba lagi writes them.
    @Test func processingAtLaunchCanBeRetried() async throws {
        let meeting = try savedMeeting(lines: Self.speech)
        let relaunched = makeStore()
        relaunched.recoverUnfinishedMinutes()
        let stopped = try #require(relaunched.meetings.first { $0.id == meeting.id })
        #expect(stopped.status == .failed)
        #expect(stopped.failure == "Pembuatan notulen terhenti. Coba lagi.")
        #expect(try saved(meeting.id).status == .failed)

        store = relaunched
        try await makeFinisher(FakeLLMClient(reply: try fixture())).regenerate(meeting.id)
        let retried = try saved(meeting.id)
        #expect(retried.status == .ready && retried.failure == nil && retried.minutes != nil)
    }

    // MARK: Views

    @Test func stepLabels() {
        #expect(MeetingFinisher.Step.separatingSpeakers.label == "Memisahkan pembicara…")
        #expect(MeetingFinisher.Step.writingMinutes.label == "Menulis notulen…")
        // Speaker separation joins in a later task.
        #expect(MeetingFinisher.steps == [.writingMinutes])
    }

    @Test func minutesViewInstantiates() throws {
        var meeting = Meeting(
            title: "Weekly", startedAt: startedAt, status: .ready, language: "id-ID", audioSource: .systemWide)
        meeting.minutes = try JSONReply.decode(Minutes.self, from: try fixture())
        _ = MinutesView(meeting: meeting)
        _ = ProcessingView(meeting: meeting, step: .writingMinutes)
    }

    @Test func metaLineHasDateTimesDurationSourceAndLanguage() throws {
        let jakarta = try #require(TimeZone(identifier: "Asia/Jakarta"))
        // Thursday 22 October 2026, 09:00 in Jakarta.
        let start = try #require(ISO8601DateFormatter().date(from: "2026-10-22T02:00:00Z"))
        var meeting = Meeting(
            title: "", startedAt: start, endedAt: start.addingTimeInterval(72 * 60), status: .ready,
            language: "id-ID", audioSource: .app(bundleID: "us.zoom.xos", name: "Zoom"))
        #expect(MinutesView.metaLine(meeting, timeZone: jakarta)
            == "Kamis, 22 Oktober 2026 · 09.00–10.12 · 1 jam 12 menit · Zoom · Bahasa Indonesia")
        meeting.endedAt = nil
        #expect(MinutesView.metaLine(meeting, timeZone: jakarta)
            == "Kamis, 22 Oktober 2026 · 09.00 · Zoom · Bahasa Indonesia")
    }

    /// The AI read "[05:12]" for a line that starts at 312.7 s.
    @Test func timeJumpsToTheLastLineStartingByThen() {
        func line(_ start: TimeInterval) -> TranscriptLine {
            TranscriptLine(channel: .meeting, speaker: .others, text: "x", start: start, end: start + 1)
        }
        let lines = [line(0.4), line(300), line(312.7), line(400)]
        #expect(MinutesView.lineID(at: 312, in: lines) == lines[2].id)
        #expect(MinutesView.lineID(at: 350, in: lines) == lines[2].id)
        #expect(MinutesView.lineID(at: 9999, in: lines) == lines[3].id)
        #expect(MinutesView.lineID(at: 0, in: lines) == lines[0].id)
        #expect(MinutesView.lineID(at: 0, in: [line(5)]) != nil)
        #expect(MinutesView.lineID(at: 10, in: []) == nil)
    }

    @Test func ownerIsTheSpeakersNameOrTheNameHeard() {
        var meeting = Meeting(
            title: "", startedAt: startedAt, status: .ready, language: "id-ID", audioSource: .systemWide,
            speakers: [SpeakerInfo(id: .remote(1), name: "Rina"), SpeakerInfo(id: .remote(2), name: nil)])
        func item(_ speaker: SpeakerID?, _ name: String?) -> Minutes.ActionItem {
            .init(id: "a", task: "t", owner: .init(speaker: speaker, name: name), due: nil, at: 0)
        }
        #expect(ActionItemRow.owner(of: item(.me, nil), in: meeting) == .init(text: "Saya", isNamed: true))
        #expect(ActionItemRow.owner(of: item(.remote(1), "Andi"), in: meeting) == .init(text: "Rina", isNamed: true))
        #expect(ActionItemRow.owner(of: item(.remote(2), "Andi"), in: meeting) == .init(text: "Andi", isNamed: true))
        #expect(ActionItemRow.owner(of: item(.remote(2), nil), in: meeting)
            == .init(text: "Pembicara 2", isNamed: false))
        #expect(ActionItemRow.owner(of: item(nil, "Budi"), in: meeting) == .init(text: "Budi", isNamed: true))
        let nobody = Minutes.ActionItem(id: "a", task: "t", owner: nil, due: nil, at: 0)
        #expect(ActionItemRow.owner(of: nobody, in: meeting) == .init(text: "Pemilik tidak disebut", isNamed: false))
        meeting.merges = [SpeakerMerge(from: .remote(2), to: .remote(1))]
        #expect(ActionItemRow.owner(of: item(.remote(2), nil), in: meeting) == .init(text: "Rina", isNamed: true))
        #expect(ActionItemRow.due(of: nobody) == "tenggat tidak disebut")
        #expect(ActionItemRow.due(of: .init(id: "a", task: "t", owner: nil, due: "Jumat", at: 0)) == "Jumat")
    }

    @Test func participantsAreMeThenSpeakersThenOthers() {
        var meeting = Meeting(
            title: "", startedAt: startedAt, status: .ready, language: "id-ID", audioSource: .systemWide,
            speakers: [SpeakerInfo(id: .remote(10), name: nil), SpeakerInfo(id: .remote(2), name: "Andi")])
        let lines = [SpeakerID.others, .remote(10), .remote(2), .me, .remote(3), .remote(2)].map {
            TranscriptLine(channel: $0 == .me ? .mic : .meeting, speaker: $0, text: "x", start: 0, end: 1)
        }
        #expect(ParticipantChips.participants(of: meeting, lines: lines)
            == [.me, .remote(2), .remote(3), .remote(10), .others])
        meeting.merges = [SpeakerMerge(from: .remote(3), to: .remote(2))]
        #expect(ParticipantChips.participants(of: meeting, lines: lines) == [.me, .remote(2), .remote(10), .others])
    }
}

/// Holds each reply until the test lets it go; replies through `stream`
/// too, which the minutes use.
private final class HeldLLMClient: LLMClient, @unchecked Sendable {
    let providerName = "Held"
    private let reply: String
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(reply: String) { self.reply = reply }

    var isWaiting: Bool { lock.withLock { !waiting.isEmpty } }

    func release() {
        let held = lock.withLock { defer { waiting = [] }; return waiting }
        held.forEach { $0.resume() }
    }

    func complete(_ request: LLMRequest) async throws -> String {
        await withCheckedContinuation { continuation in
            lock.withLock { waiting.append(continuation) }
        }
        return reply
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(try await complete(request))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
