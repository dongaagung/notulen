import Foundation
import Testing
@testable import Notulen

@MainActor
final class MicTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "NotulenTests-\(UUID().uuidString)")
    let meetingCapture = FakeCapture.meeting()
    let micCapture = FakeCapture.mic()
    let outputRoute = FakeOutputRoute()
    let clock = TestClock()
    /// No real power assertion, and deaf to the system's sleep.
    let power = PowerGuard.fake()
    let config = MeetingSession.Configuration(
        title: "Weekly sync", audioSource: .systemWide, locale: Locale(identifier: "id-ID"), vocabulary: [])
    private(set) lazy var store = makeStore()

    deinit { try? FileManager.default.removeItem(at: root) }

    private func makeStore() -> AppStore {
        AppStore(files: JSONFileStore(directory: root), keychainPrefix: "test-\(UUID().uuidString)-")
    }

    /// The clock stands still until the test moves it, so capture starts at
    /// meeting time 0.
    private func makeSession(_ speech: FakeSpeech = FakeSpeech()) -> MeetingSession {
        let devices = CaptureDevices(meeting: meetingCapture, mic: micCapture, output: outputRoute)
        let clock = clock
        // No AI: lines too short to be speech end ready without minutes.
        return MeetingSession(
            store: store, finisher: MeetingFinisher(store: store, diarizer: nil) { nil },
            devices: { _ in devices }, speech: { _, _ in speech }, now: { clock.now },
            power: power)
    }

    private func savedMicOff() -> [TimeSpan]? {
        makeStore().meetings.first?.micOff
    }

    // MARK: Tracker

    @Test func micOffSpansAreRecorded() {
        var t = MicOffTracker(); t.turnOff(at: 60); t.turnOn(at: 90); t.turnOff(at: 200); t.close(at: 260)
        #expect(t.spans == [.init(start: 60, end: 90), .init(start: 200, end: 260)])
    }

    @Test func turningOffTwiceKeepsFirstStart() {
        var t = MicOffTracker(); t.turnOff(at: 10); t.turnOff(at: 20); t.turnOn(at: 30)
        #expect(t.spans == [.init(start: 10, end: 30)])
        #expect(!t.isOff)
    }

    /// A period still going on counts up to a given time; closing or turning
    /// on twice changes nothing.
    @Test func openSpanCountsUpToAGivenTime() {
        var t = MicOffTracker(spans: [.init(start: 5, end: 8)])
        t.turnOn(at: 9)
        t.turnOff(at: 60)
        #expect(t.isOff)
        #expect(t.spans == [.init(start: 5, end: 8)])
        #expect(t.spans(through: 75) == [.init(start: 5, end: 8), .init(start: 60, end: 75)])
        t.close(at: 80)
        t.close(at: 90)
        #expect(!t.isOff)
        #expect(t.spans == [.init(start: 5, end: 8), .init(start: 60, end: 80)])
        #expect(t.spans(through: 100) == t.spans)
    }

    // MARK: Copy

    @Test func noticeCopy() {
        #expect(MeetingNotice.micChanged("AirPods Pro").message == "Mic berganti ke AirPods Pro.")
        #expect(MeetingNotice.speakerOutput.message
            == "Suara meeting keluar lewat speaker Mac. Suara peserta lain bisa masuk ke mic dan terlabel “Saya”. Pakai headset.")
        #expect(LiveMeetingView.micToggleHelp(micOn: true) == "Matikan mic (⇧⌘M)")
        #expect(LiveMeetingView.micToggleHelp(micOn: false) == "Nyalakan mic (⇧⌘M)")
    }

    // MARK: Turning the mic off and on

    @MainActor @Test func mutingPausesMicAndSavesSpan() async throws {
        let session = makeSession()
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        #expect(session.isMicOn)
        clock.advance(60)
        session.setMicEnabled(false)
        #expect(!session.isMicOn)
        #expect(micCapture.pauseCount == 1 && micCapture.resumeCount == 0)
        // Saved at once, so a crash keeps when the mic went off.
        #expect(savedMicOff() == [.init(start: 60, end: 60)])
        session.setMicEnabled(false)
        #expect(micCapture.pauseCount == 1)

        clock.advance(30)
        session.setMicEnabled(true)
        #expect(session.isMicOn)
        #expect(micCapture.pauseCount == 1 && micCapture.resumeCount == 1)
        #expect(savedMicOff() == [.init(start: 60, end: 90)])
        // The meeting audio records on throughout.
        #expect(meetingCapture.pauseCount == 0 && meetingCapture.isCapturing)
        clock.advance(30)
        _ = await session.stop()
        #expect(savedMicOff()?.count == 1)
    }

    /// Speech spans count the audio fed, and none flows while the mic is
    /// off: a line after it's back on counts from then, not from where the
    /// mic stopped. Nothing the mic hears while off becomes a line.
    @Test func micLinesAfterTurningOnCountFromThen() async throws {
        let session = makeSession(FakeSpeech(mic: [.final("Halo", 1, 2)]))
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        clock.advance(60)
        session.setMicEnabled(false)
        micCapture.send()
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.transcript.lines.isEmpty)

        clock.advance(30)
        session.setMicEnabled(true)
        micCapture.send()
        #expect(await waitUntil { session.transcript.lines.count == 1 })
        let line = try #require(session.transcript.lines.first)
        #expect(line.start == 91 && line.end == 92)
        #expect(line.speaker == .me)
        let stopped = try #require(await session.stop())
        #expect(try TranscriptJournal.read(#require(store.transcriptURL(for: stopped.id))).map(\.start) == [91])
    }

    /// What the recognizer still finalizes from before the mic went off
    /// keeps its own time, even once the mic is back on.
    @Test func lastWordsBeforeMutingKeepTheirTime() async throws {
        let session = makeSession(FakeSpeech(mic: [.final("Halo", 1, 2)], startDelay: .milliseconds(300)))
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        micCapture.send()
        // Let the relay hand the chunk to speech before the mic goes off.
        try await Task.sleep(for: .milliseconds(50))
        clock.advance(60)
        session.setMicEnabled(false)
        clock.advance(30)
        session.setMicEnabled(true)
        micCapture.send()
        #expect(await waitUntil { session.transcript.lines.count == 2 })
        #expect(session.transcript.lines.map(\.start).sorted() == [1, 91])
        _ = await session.stop()
    }

    @Test func togglingWhileNotRecordingDoesNothing() async throws {
        let session = makeSession()
        session.setMicEnabled(false)
        #expect(session.isMicOn)
        try session.begin(config)
        // Still starting.
        session.setMicEnabled(false)
        #expect(session.isMicOn)
        #expect(await waitUntil { session.phase == .recording })
        _ = await session.stop()
        session.setMicEnabled(false)
        #expect(session.isMicOn)
        #expect(micCapture.pauseCount == 0)
        #expect(savedMicOff() == [])
    }

    /// Selesai or quitting with the mic off ends its period there.
    @Test(arguments: [MeetingStatus.ready, .interrupted])
    func endingTheRecordingClosesAnOpenSpan(as status: MeetingStatus) async throws {
        let session = makeSession()
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        clock.advance(60)
        session.setMicEnabled(false)
        clock.advance(60)
        if status == .ready {
            _ = await session.stop()
        } else {
            await session.interrupt()
        }
        let saved = try #require(makeStore().meetings.first)
        #expect(saved.status == status)
        #expect(saved.micOff == [.init(start: 60, end: 120)])
        #expect(micCapture.resumeCount == 0)
    }

    /// The Mac sleeping doesn't turn the mic back on: after the wake it stays
    /// off, without being opened, and its period runs on through the sleep.
    @Test func micStaysOffAcrossSleep() async throws {
        let session = makeSession(FakeSpeech(mic: [.final("Halo", 1, 2)]))
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        clock.advance(60)
        session.setMicEnabled(false)
        clock.advance(40)
        session.handleWillSleep()
        clock.advance(60)
        await session.handleDidWake()
        #expect(await waitUntil { meetingCapture.isCapturing })
        #expect(!session.isMicOn)
        #expect(!micCapture.isCapturing)

        clock.advance(40)
        session.setMicEnabled(true)
        #expect(session.isMicOn && micCapture.isCapturing)
        micCapture.send()
        #expect(await waitUntil { session.transcript.lines.count == 1 })
        #expect(session.transcript.lines.first?.start == 201)
        clock.advance(60)
        let stopped = try #require(await session.stop())
        #expect(stopped.micOff == [.init(start: 60, end: 200)])
        #expect(stopped.gaps == [Gap(span: .init(start: 100, end: 160), reason: .sleep)])
    }

    /// Capture that can't start again after a wake leaves the meeting
    /// interrupted, and a mic left off ends its period where recording
    /// stopped. With the mic off nothing else would record.
    @Test func failedRestartAfterWakeClosesTheMicOffPeriod() async throws {
        let session = makeSession()
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        clock.advance(60)
        session.setMicEnabled(false)
        clock.advance(40)
        session.handleWillSleep()
        meetingCapture.startError = ProcessTapCapture.Failure.unsupportedFormat
        clock.advance(60)
        await session.handleDidWake()

        #expect(await waitUntil { session.phase == .idle })
        let saved = try #require(makeStore().meetings.first)
        #expect(saved.status == .interrupted)
        #expect(saved.micOff == [.init(start: 60, end: 100)])
        #expect(!micCapture.isCapturing)
    }

    /// A meeting resumed after a crash keeps the periods saved before it.
    @Test func resumingKeepsEarlierMicOffPeriods() async throws {
        var crashed = Meeting(
            title: "Weekly sync", startedAt: clock.now.addingTimeInterval(-300), status: .interrupted,
            language: "id-ID", audioSource: .systemWide)
        crashed.micOff = [.init(start: 10, end: 20)]
        store.save(crashed)
        let session = makeSession()
        try session.resume(crashed)
        #expect(await waitUntil { micCapture.isCapturing })
        #expect(session.isMicOn)
        session.setMicEnabled(false)
        clock.advance(10)
        session.setMicEnabled(true)
        #expect(savedMicOff() == [.init(start: 10, end: 20), .init(start: 300, end: 310)])
        _ = await session.stop()
    }

    /// A mic that can't come back on stays off, and the owner hears why
    /// until it does come back on.
    @Test func micThatCannotComeBackOnStaysOff() async throws {
        let session = makeSession()
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        clock.advance(60)
        session.setMicEnabled(false)
        micCapture.resumeError = MicCapture.Failure.noInputDevice
        clock.advance(30)
        session.setMicEnabled(true)
        #expect(!session.isMicOn)
        #expect(session.notices == [.error("Mic tidak bisa dinyalakan: Mikrofon tidak ditemukan.")])
        #expect(savedMicOff() == [.init(start: 60, end: 60)])

        micCapture.resumeError = nil
        clock.advance(30)
        session.setMicEnabled(true)
        #expect(session.isMicOn)
        #expect(session.notices.isEmpty)
        let stopped = try #require(await session.stop())
        #expect(stopped.micOff == [.init(start: 60, end: 120)])
    }

    // MARK: Device notices

    @Test func micChangeIsAnnounced() async throws {
        let session = makeSession()
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        micCapture.changeDevice(to: "AirPods Pro")
        #expect(session.notices == [.micChanged("AirPods Pro")])
        // Only the latest move is shown.
        micCapture.changeDevice(to: "MacBook Pro Microphone")
        #expect(session.notices == [.micChanged("MacBook Pro Microphone")])
        _ = await session.stop()
    }

    /// The live view's meta line names the mic, and follows it to a new device.
    @Test func micNameFollowsTheInputDevice() async throws {
        micCapture.deviceName = "MacBook Pro Microphone"
        let session = makeSession()
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        #expect(session.micName == "MacBook Pro Microphone")
        micCapture.changeDevice(to: "AirPods Pro")
        #expect(session.micName == "AirPods Pro")
        _ = await session.stop()
    }

    /// Checked as recording starts and whenever the output route changes;
    /// shown only while the sound comes out of the Mac's speakers.
    @Test func speakerOutputIsShownWhileTheMeetingPlaysThroughTheMac() async throws {
        outputRoute.isBuiltInSpeaker = true
        let session = makeSession()
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        #expect(session.notices == [.speakerOutput])
        #expect(outputRoute.isMonitoring)
        outputRoute.change(toBuiltInSpeaker: false)
        #expect(session.notices.isEmpty)
        outputRoute.change(toBuiltInSpeaker: true)
        #expect(session.notices == [.speakerOutput])
        _ = await session.stop()
        #expect(!outputRoute.isMonitoring)
    }

    /// A headset that went away while the Mac slept is noticed as recording
    /// goes on.
    @Test func speakerOutputIsCheckedAgainAfterAWake() async throws {
        let session = makeSession()
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        #expect(session.notices.isEmpty)
        clock.advance(60)
        session.handleWillSleep()
        #expect(!outputRoute.isMonitoring)
        outputRoute.change(toBuiltInSpeaker: true)
        clock.advance(60)
        await session.handleDidWake()
        #expect(await waitUntil { session.notices.contains(.speakerOutput) })
        #expect(outputRoute.isMonitoring)
        _ = await session.stop()
    }

    /// The real monitor registers and removes its Core Audio listeners
    /// cleanly, any number of times, and reads the route as `OutputRoute` does.
    @Test func outputRouteMonitorStartsAndStops() {
        let monitor = OutputRouteMonitor()
        monitor.stop()
        monitor.start()
        monitor.start()
        #expect(monitor.isBuiltInSpeaker == OutputRoute.isBuiltInSpeaker())
        monitor.stop()
        monitor.stop()
    }
}
