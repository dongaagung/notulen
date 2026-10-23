import Foundation
import Testing
@testable import Notulen

@MainActor
final class RecoveryTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "NotulenTests-\(UUID().uuidString)")
    let meetingCapture = FakeCapture.meeting()
    let micCapture = FakeCapture.mic()
    let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) lazy var store = makeStore()

    deinit { try? FileManager.default.removeItem(at: root) }

    private func makeStore() -> AppStore {
        AppStore(files: JSONFileStore(directory: root), keychainPrefix: "test-\(UUID().uuidString)-")
    }

    /// The clock stands still 300 s after `startedAt`.
    private func makeSession(_ speech: FakeSpeech = FakeSpeech()) -> MeetingSession {
        let devices = CaptureDevices(meeting: meetingCapture, mic: micCapture)
        let now = startedAt.addingTimeInterval(300)
        return MeetingSession(store: store, devices: { _ in devices }, speech: { _, _ in speech }, now: { now })
    }

    private func meeting(_ status: MeetingStatus, startedAt: Date? = nil) -> Meeting {
        Meeting(
            title: "Weekly sync", startedAt: startedAt ?? self.startedAt, status: status,
            language: "id-ID", audioSource: .systemWide)
    }

    private func line(_ start: TimeInterval, _ end: TimeInterval) -> TranscriptLine {
        TranscriptLine(channel: .meeting, speaker: .others, text: "Baris \(Int(start))", start: start, end: end)
    }

    /// A meeting a crash cut off, saved with `lines` in its journal.
    private func interruptedMeeting(lines: [TranscriptLine]) throws -> Meeting {
        let meeting = meeting(.interrupted)
        store.save(meeting)
        let journal = try TranscriptJournal(url: #require(store.transcriptURL(for: meeting.id)))
        for line in lines { try journal.append(line) }
        journal.close()
        return meeting
    }

    private func journal(_ meeting: Meeting) throws -> [TranscriptLine] {
        try TranscriptJournal.read(#require(store.transcriptURL(for: meeting.id)))
    }

    // MARK: Launch

    @Test func recordingMeetingsBecomeInterrupted() {
        let crashed = meeting(.recording)
        let done = meeting(.ready, startedAt: startedAt.addingTimeInterval(-86_400))
        store.save(crashed)
        store.save(done)

        let recovered = makeStore().recoverInterrupted()
        #expect(recovered.map(\.status) == [.interrupted])
        #expect(recovered.map(\.id) == [crashed.id])
        let reloaded = makeStore()
        #expect(reloaded.meetings.first { $0.id == crashed.id }?.status == .interrupted)
        #expect(reloaded.meetings.first { $0.id == done.id }?.status == .ready)
    }

    /// A meeting the owner quit during is asked about at the next launch too.
    @Test func meetingsLeftByQuittingAreOfferedNewestFirst() {
        let quit = meeting(.interrupted, startedAt: startedAt.addingTimeInterval(-3_600))
        let crashed = meeting(.recording)
        store.save(quit)
        store.save(crashed)
        #expect(makeStore().recoverInterrupted().map(\.id) == [crashed.id, quit.id])
    }

    // MARK: Resume

    @Test func resumeAddsCrashGapAndKeepsLines() async throws {
        let meeting = try interruptedMeeting(lines: [line(0, 60), line(65, 120)])
        let session = makeSession()
        try session.resume(meeting)
        #expect(session.meeting?.gaps == [Gap(span: .init(start: 120, end: 300), reason: .crash)])
        #expect(session.transcript.lines.count == 2 && session.phase == .recording)
        let saved = makeStore().meetings.first
        #expect(saved?.status == .recording)
        #expect(saved?.gaps == session.meeting?.gaps)
        _ = await session.stop()
    }

    @Test func resumeWithoutLinesGapsFromTheStart() async throws {
        let meeting = meeting(.interrupted)
        store.save(meeting)
        let session = makeSession()
        try session.resume(meeting)
        #expect(session.meeting?.gaps == [Gap(span: .init(start: 0, end: 300), reason: .crash)])
        #expect(session.transcript.lines.isEmpty)
        _ = await session.stop()
    }

    /// Meeting time goes on from the original start; both channels restart
    /// at the time of the resume and append to the same journal.
    @Test func resumedMeetingRecordsOnInTheSameJournal() async throws {
        let meeting = try interruptedMeeting(lines: [line(0, 60), line(65, 120)])
        let session = makeSession(FakeSpeech(meeting: [.final("Lanjut", 1, 2)], mic: [.final("Oke", 3, 4)]))
        try session.resume(meeting)
        #expect(await waitUntil { meetingCapture.isCapturing && micCapture.isCapturing })
        meetingCapture.send()
        #expect(await waitUntil { session.transcript.lines.count == 3 })
        micCapture.send()
        #expect(await waitUntil { session.transcript.lines.count == 4 })
        let stopped = try #require(await session.stop())

        #expect(stopped.startedAt == startedAt)
        #expect(stopped.status == .ready)
        let lines = try journal(meeting)
        #expect(lines.map(\.text) == ["Baris 0", "Baris 65", "Lanjut", "Oke"])
        #expect(lines.suffix(2).map(\.start) == [301, 303])
    }

    @Test func stoppingWhileResumeStartsLeavesNothingCapturing() async throws {
        let meeting = try interruptedMeeting(lines: [line(0, 60)])
        let session = makeSession()
        try session.resume(meeting)
        let stopped = await session.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(stopped?.status == .ready)
        #expect(session.phase == .idle && session.startupStatus == nil)
        #expect(!meetingCapture.isCapturing && !micCapture.isCapturing)
    }

    @Test func secondMeetingCannotBeResumedWhileRecording() async throws {
        let meeting = try interruptedMeeting(lines: [])
        let session = makeSession()
        try session.resume(meeting)
        #expect(throws: MeetingSession.StartError.alreadyRecording) { try session.resume(meeting) }
        _ = await session.stop()
    }

    // MARK: Finish

    /// The meeting ends where its recording stopped, not when the owner answered.
    @Test func finishInterruptedEndsAtTheLastLine() async throws {
        let meeting = try interruptedMeeting(lines: [line(0, 60), line(65, 120)])
        await makeSession().finishInterrupted(meeting)
        let saved = makeStore().meetings.first
        #expect(saved?.status == .ready)
        #expect(saved?.endedAt == startedAt.addingTimeInterval(120))
        #expect(try journal(meeting).count == 2)
    }

    // MARK: Quit

    @Test func quittingSavesTheMeetingAsInterrupted() async throws {
        let session = makeSession(FakeSpeech(meeting: [.final("Halo", 1, 2)]))
        try session.begin(MeetingSession.Configuration(
            title: "Weekly sync", audioSource: .systemWide, locale: Locale(identifier: "id-ID"), vocabulary: []))
        #expect(await waitUntil { session.phase == .recording })
        meetingCapture.send()
        #expect(await waitUntil { session.transcript.lines.count == 1 })
        await session.interrupt()

        #expect(session.phase == .idle)
        #expect(!meetingCapture.isCapturing && !micCapture.isCapturing)
        let saved = try #require(makeStore().meetings.first)
        #expect(saved.status == .interrupted && saved.endedAt == nil)
        #expect(try journal(saved).map(\.text) == ["Halo"])
        #expect(makeStore().recoverInterrupted().map(\.id) == [saved.id])
    }
}
