import Foundation
import Testing
@testable import Notulen

@MainActor
final class MeetingSessionTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "NotulenTests-\(UUID().uuidString)")
    let meetingCapture = FakeCapture.meeting()
    let micCapture = FakeCapture.mic()
    /// No real power assertion, and deaf to the system's sleep.
    let power = PowerGuard.fake()
    let config = MeetingSession.Configuration(
        title: "Weekly sync", audioSource: .systemWide, locale: Locale(identifier: "id-ID"), vocabulary: [])
    private(set) lazy var store = makeStore()

    deinit { try? FileManager.default.removeItem(at: root) }

    private func makeStore() -> AppStore {
        AppStore(files: JSONFileStore(directory: root), keychainPrefix: "test-\(UUID().uuidString)-")
    }

    /// The clock stands still, so both channels start at meeting time 0 and a
    /// line's times are its span.
    private func makeSession(
        _ speech: FakeSpeech = FakeSpeech(),
        audioBuffer: @escaping () -> MeetingAudioBuffer = { MeetingAudioBuffer() }
    ) -> MeetingSession {
        let devices = CaptureDevices(meeting: meetingCapture, mic: micCapture, output: FakeOutputRoute())
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        return MeetingSession(
            store: store, devices: { _ in devices }, speech: { _, _ in speech }, now: { clock },
            audioBuffer: audioBuffer, power: power)
    }

    private func journal(_ meeting: Meeting) throws -> [TranscriptLine] {
        try TranscriptJournal.read(#require(store.transcriptURL(for: meeting.id)))
    }

    @Test func finalLinesAreJournaledWithChannelAndSpeaker() async throws {
        let session = makeSession(FakeSpeech(
            meeting: [.final("Selamat pagi", 1, 2)],
            mic: [.final("Pagi", 3, 4)]))
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        meetingCapture.send()
        #expect(await waitUntil { session.transcript.lines.count == 1 })
        micCapture.send()
        #expect(await waitUntil { session.transcript.lines.count == 2 })
        let meeting = try #require(await session.stop())

        let lines = try journal(meeting)
        #expect(lines.map(\.speaker) == [.others, .me])
        #expect(lines.map(\.channel) == [.meeting, .mic])
        #expect(lines.map(\.text) == ["Selamat pagi", "Pagi"])
        #expect(lines.map(\.start) == [1, 3] && lines.map(\.end) == [2, 4])
    }

    @Test func secondMeetingCannotStart() async throws {
        let session = makeSession()
        try session.begin(config)
        #expect(throws: MeetingSession.StartError.alreadyRecording) { try session.begin(config) }
        #expect(await waitUntil { session.phase == .recording })
        #expect(throws: MeetingSession.StartError.alreadyRecording) { try session.begin(config) }
        _ = await session.stop()
        #expect(store.meetings.count == 1)
    }

    @Test func stopMarksMeetingEnded() async throws {
        let session = makeSession()
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        #expect(store.meetings.first?.status == .recording)
        #expect(store.meetings.first?.endedAt == nil)
        #expect(power.preventsSleep)
        _ = await session.stop()
        #expect(!power.preventsSleep)
        #expect(store.meetings.first?.endedAt != nil)
        #expect(store.meetings.first?.status == .ready)
        #expect(makeStore().meetings.first?.status == .ready)
        #expect(session.phase == .idle)
        #expect(!meetingCapture.isCapturing && !micCapture.isCapturing)
    }

    @Test func micEchoOfTheMeetingIsDropped() async throws {
        let said = "Kita mulai rapat mingguan sekarang"
        let session = makeSession(FakeSpeech(
            meeting: [.final(said, 1, 3)],
            mic: [.final(said.lowercased(), 1.2, 3), .final("Oke", 4, 5)]))
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        meetingCapture.send()
        #expect(await waitUntil { session.transcript.lines.count == 1 })
        micCapture.send()
        #expect(await waitUntil { session.transcript.lines.count == 2 })
        let meeting = try #require(await session.stop())
        #expect(try journal(meeting).map(\.text) == [said, "Oke"])
    }

    /// The recognizer reads nothing while its analyzer starts. A chunk
    /// dropped then would make every later line of that channel early.
    @Test func noAudioIsDroppedWhileTheRecognizerStarts() async throws {
        let received = ReceivedAudio()
        let session = makeSession(FakeSpeech(startDelay: .milliseconds(300), received: received))
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        // 300 chunks each, well over the captures' 128, sent in bursts the
        // session's relays can keep up with, as with real capture callbacks.
        for burst in 0..<15 {
            for _ in 0..<20 {
                meetingCapture.send(.audible(channels: 2, frames: 512))
                micCapture.send(.audible(channels: 1, frames: 512))
            }
            if burst < 14 { try await Task.sleep(for: .milliseconds(2)) }
        }
        #expect(await waitUntil { received.count(.meeting) == 300 && received.count(.mic) == 300 })
        _ = await session.stop()
        #expect(received.count(.meeting) == 300)
        #expect(received.count(.mic) == 300)
    }

    @Test func fullSpeakerAudioIsReportedOnce() async throws {
        // 0.1 s at 48 kHz is ~1600 samples at 16 kHz: over this cap at once.
        let session = makeSession(audioBuffer: { MeetingAudioBuffer(maxSamples: 1_000, chunkSamples: 1_000) })
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        meetingCapture.send()
        meetingCapture.send()
        #expect(await waitUntil { session.notices.contains(.speakerAudioFull) })
        _ = await session.stop()
        #expect(session.notices == [.speakerAudioFull])
    }

    @Test func micKeepsRecordingWhenMeetingAudioFails() async throws {
        let failure = ProcessTapCapture.Failure.appNotRunning("Zoom")
        meetingCapture.startError = failure
        let session = makeSession(FakeSpeech(mic: [.final("Halo", 0, 1)]))
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        #expect(session.notices == [.error(failure.localizedDescription)])
        micCapture.send()
        #expect(await waitUntil { session.transcript.lines.count == 1 })
        _ = await session.stop()
        #expect(store.meetings.first?.status == .ready)
    }

    @Test func meetingFailsWhenNoChannelStarts() async throws {
        meetingCapture.startError = ProcessTapCapture.Failure.unsupportedFormat
        micCapture.startError = MicCapture.Failure.noInputDevice
        let session = makeSession()
        try session.begin(config)
        #expect(await waitUntil { session.phase == .idle })
        #expect(store.meetings.first?.status == .failed)
        #expect(store.meetings.first?.failure != nil)
        #expect(session.notices.count == 2)
        #expect(!power.preventsSleep)
    }

    @Test func cancellingTheStartRemovesTheMeeting() async throws {
        let session = makeSession()
        try session.begin(config)
        #expect(store.meetings.count == 1)
        session.cancelStart()
        #expect(session.phase == .idle && session.meeting == nil)
        #expect(store.meetings.isEmpty && makeStore().meetings.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.phase == .idle && !meetingCapture.isCapturing)
        #expect(!power.preventsSleep)
    }

    @Test func noticeCopy() {
        #expect(MeetingNotice.silent.message.hasPrefix("Belum ada suara dari meeting."))
        #expect(MeetingNotice.error("Mic berhenti merekam.").message == "Mic berhenti merekam.")
        #expect(MeetingNotice.speakerAudioFull.message == "Batas 4 jam audio untuk pemisahan pembicara tercapai. Sisa meeting tetap ditranskripsi dan berlabel Lainnya.")
        #expect(MeetingNotice.speakerAudioFailed.message == "Audio meeting untuk pemisahan pembicara gagal diproses.")
        #expect(MeetingSession.StartError.alreadyRecording.localizedDescription
            == "Meeting lain masih direkam. Selesaikan dulu.")
    }
}
