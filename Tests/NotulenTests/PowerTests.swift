import AppKit
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Notulen

@MainActor
final class PowerTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "NotulenTests-\(UUID().uuidString)")
    let meetingCapture = FakeCapture.meeting()
    let micCapture = FakeCapture.mic()
    let clock = TestClock()
    let config = MeetingSession.Configuration(
        title: "Weekly sync", audioSource: .systemWide, locale: Locale(identifier: "id-ID"), vocabulary: [])
    /// Records only Zoom, so the meeting can end by Zoom quitting.
    let zoomConfig = MeetingSession.Configuration(
        title: "Weekly sync", audioSource: .app(bundleID: "us.zoom.xos", name: "Zoom"),
        locale: Locale(identifier: "id-ID"), vocabulary: [])
    let power = PowerGuard.fake()
    /// What the fake `NSRunningApplication` check answers.
    var appIsRunning = true
    /// How many times the session asked for capture devices.
    private(set) var deviceRequests = 0
    /// Sleep and wake as a `PowerGuard` reported them.
    private(set) var powerEvents: [String] = []
    private(set) lazy var store = makeStore()

    deinit { try? FileManager.default.removeItem(at: root) }

    private func makeStore() -> AppStore {
        AppStore(files: JSONFileStore(directory: root), keychainPrefix: "test-\(UUID().uuidString)-")
    }

    /// The clock stands still until the test moves it, so capture starts at
    /// meeting time 0. Sleep and wake reach the session only through its
    /// fake `PowerGuard` (`self.power` unless given), never the system's.
    private func makeSession(
        _ speech: FakeSpeech = FakeSpeech(),
        audioBuffer: @escaping () -> MeetingAudioBuffer = { MeetingAudioBuffer() },
        power: PowerGuard? = nil
    ) -> MeetingSession {
        let devices = CaptureDevices(meeting: meetingCapture, mic: micCapture, output: FakeOutputRoute())
        let clock = clock
        // No AI: lines too short to be speech end ready without minutes.
        return MeetingSession(
            store: store, finisher: MeetingFinisher(store: store, diarizer: nil) { nil },
            devices: { [unowned self] _ in
                deviceRequests += 1
                return devices
            },
            speech: { _, _ in speech }, now: { clock.now }, audioBuffer: audioBuffer,
            appRunning: { [unowned self] _ in appIsRunning },
            power: power ?? self.power)
    }

    private func journal(_ meeting: Meeting) throws -> [TranscriptLine] {
        try TranscriptJournal.read(#require(store.transcriptURL(for: meeting.id)))
    }

    // MARK: Rules

    @Test func wakeRule() {
        #expect(WakePolicy.decision(sleptFor: 14 * 60) == .resume)
        #expect(WakePolicy.decision(sleptFor: 15 * 60) == .resume)
        #expect(WakePolicy.decision(sleptFor: 15 * 60 + 1) == .ask)
    }

    // `#expect` can't call a mutating method, so the offers are worked out
    // before it.

    @Test func offersAfterTenQuietMinutesOnce() {
        var d = MeetingEndDetector(startedAt: 0); d.heardSound(at: 100)
        let offers = [699, 700, 701].map { d.shouldOffer(at: $0, appRunning: true) }
        #expect(offers == [false, true, false])
    }

    @Test func offersWhenMeetingAppQuits() {
        var d = MeetingEndDetector(startedAt: 0)
        let offer = d.shouldOffer(at: 5, appRunning: false)
        #expect(offer)
    }

    @Test func declineWaitsAnotherTenMinutes() {
        var d = MeetingEndDetector(startedAt: 0); d.heardSound(at: 100)
        let offered = d.shouldOffer(at: 700, appRunning: true)
        d.declined(at: 700)
        let offers = [1299, 1300].map { d.shouldOffer(at: $0, appRunning: true) }
        #expect(offered)
        #expect(offers == [false, true])
    }

    @Test func soundRestartsTheQuietClock() {
        var d = MeetingEndDetector(startedAt: 0); d.heardSound(at: 100)
        d.heardSound(at: 650)
        let offers = [700, 1250].map { d.shouldOffer(at: $0, appRunning: true) }
        #expect(offers == [false, true])
    }

    /// An app that's still gone after "Tetap merekam" isn't offered again;
    /// one that quits again after coming back is.
    @Test func appQuitIsOfferedOncePerQuit() {
        var d = MeetingEndDetector(startedAt: 0)
        let offered = d.shouldOffer(at: 5, appRunning: false)
        d.declined(at: 5)
        let running: [(at: TimeInterval, running: Bool)] = [(15, false), (25, true), (35, false)]
        let offers = running.map { d.shouldOffer(at: $0.at, appRunning: $0.running) }
        #expect(offered)
        #expect(offers == [false, false, true])
    }

    /// Tetap merekam while the app is gone covers its quit too, even if it
    /// quit while a quiet offer was showing.
    @Test func declineWhileTheAppIsGoneCoversItsQuit() {
        var d = MeetingEndDetector(startedAt: 0)
        let quiet = d.shouldOffer(at: 600, appRunning: true)
        d.declined(at: 630, appRunning: false)
        let checks: [(at: TimeInterval, running: Bool)] = [(640, false), (1229, false), (1230, false)]
        let offers = checks.map { d.shouldOffer(at: $0.at, appRunning: $0.running) }
        #expect(quiet)
        #expect(offers == [false, false, true])
    }

    /// Meeting audio starting again after a wake restarts only the quiet
    /// clock; a declined quit stays declined.
    @Test func restartingTheQuietClockKeepsWhatWasDeclined() {
        var d = MeetingEndDetector(startedAt: 0)
        let quit = d.shouldOffer(at: 5, appRunning: false)
        d.declined(at: 5, appRunning: false)
        d.restartQuietClock(at: 100)
        let offers = [110, 699, 700].map { d.shouldOffer(at: $0, appRunning: false) }
        #expect(quit)
        #expect(offers == [false, false, true])
    }

    @Test func sleepCopy() {
        #expect(MeetingTime.duration(45) == "45 detik")
        #expect(MeetingTime.duration(12 * 60) == "12 menit")
        #expect(MeetingTime.duration(12 * 60 + 20) == "12 menit")
        #expect(MeetingTime.duration(80 * 60) == "1 jam 20 menit")
        #expect(MeetingTime.duration(2 * 3600) == "2 jam")
        #expect(MeetingNotice.resumedAfterSleep(720).message == "Rekaman dilanjutkan setelah Mac tidur 12 menit.")
        #expect(LiveMeetingView.wakeQuestion(sleptFor: 80 * 60, title: "Weekly Sync")
            == "Mac tidur selama 1 jam 20 menit. Lanjutkan merekam “Weekly Sync” atau Selesaikan?")
        #expect(LiveMeetingView.finishOffer == "Meeting sepertinya sudah selesai. Selesaikan rekaman?")
    }

    // MARK: PowerGuard

    @Test func powerGuardKeepsTheMacAwakeAndReportsSleepAndWake() async {
        let center = NotificationCenter()
        let power = PowerGuard(notificationCenter: center)
        power.onWillSleep = { [unowned self] in powerEvents.append("sleep") }
        power.onDidWake = { [unowned self] in powerEvents.append("wake") }

        power.begin()
        #expect(power.preventsSleep)
        #expect(ownAssertionNames().contains("Notulen sedang merekam"))
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(await waitUntil { powerEvents == ["sleep"] })
        // The Mac sleeps anyway; recording again takes the assertion again.
        #expect(!power.preventsSleep)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { powerEvents == ["sleep", "wake"] })
        power.begin()
        #expect(power.preventsSleep)

        // Other suites' sessions may hold an assertion of the same name now,
        // so only this guard's own state is checked.
        power.end()
        #expect(!power.preventsSleep)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(powerEvents == ["sleep", "wake"])
    }

    /// Names of the power assertions this process holds.
    private func ownAssertionNames() -> [String] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }
        return all[NSNumber(value: getpid())]?.compactMap { $0[kIOPMAssertionNameKey] as? String } ?? []
    }

    // MARK: Sleep and wake

    /// Up to 15 minutes: recording goes on by itself in the same journal,
    /// with the sleep as a gap and new audio in a new buffer segment.
    @Test func shortSleepResumesOnItsOwn() async throws {
        let buffer = MeetingAudioBuffer()
        let session = makeSession(FakeSpeech(meeting: [.final("Halo", 1, 2)]), audioBuffer: { buffer })
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        meetingCapture.send()
        #expect(await waitUntil { session.transcript.lines.count == 1 })
        clock.advance(60)

        #expect(power.preventsSleep)
        session.handleWillSleep()
        #expect(!meetingCapture.isCapturing && !micCapture.isCapturing)
        #expect(session.phase == .recording)
        clock.advance(12 * 60)
        await session.handleDidWake()

        #expect(session.wakeQuestion == nil)
        let gaps = [Gap(span: .init(start: 60, end: 780), reason: .sleep)]
        #expect(session.meeting?.gaps == gaps)
        let saved = makeStore().meetings.first
        #expect(saved?.status == .recording && saved?.gaps == gaps)
        #expect(session.notices == [.resumedAfterSleep(720)])
        #expect(await waitUntil { meetingCapture.isCapturing && micCapture.isCapturing })
        // Nothing writes to the buffer until the next chunk arrives.
        let recorded = Double(buffer.sampleCount) / MeetingAudioBuffer.sampleRate
        #expect(buffer.meetingTime(ofBufferTime: recorded) == 780)

        meetingCapture.send()
        #expect(await waitUntil { session.transcript.lines.count == 2 })
        #expect(power.preventsSleep)
        let stopped = try #require(await session.stop())
        #expect(try journal(stopped).map(\.start) == [1, 781])
        #expect(stopped.status == .ready)
        #expect(!power.preventsSleep)
    }

    /// Over 15 minutes: nothing records until the owner answers, and the
    /// sleep gap ends at the answer.
    @Test func longSleepAsksFirst() async throws {
        let session = makeSession()
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        clock.advance(60)
        session.handleWillSleep()
        clock.advance(80 * 60)
        await session.handleDidWake()

        #expect(session.wakeQuestion == 80.0 * 60)
        // Nothing is checked meanwhile: no silence warning, no offer.
        session.checkMeeting()
        #expect(!session.offersFinish)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!meetingCapture.isCapturing && !micCapture.isCapturing)
        #expect(session.meeting?.gaps == [])
        #expect(session.notices.isEmpty)

        clock.advance(30)
        await session.answerWake(continueRecording: true)
        #expect(session.wakeQuestion == nil)
        #expect(session.meeting?.gaps == [Gap(span: .init(start: 60, end: 4_890), reason: .sleep)])
        #expect(await waitUntil { meetingCapture.isCapturing && micCapture.isCapturing })
        #expect(power.preventsSleep)
        #expect(session.notices.isEmpty)
        _ = await session.stop()
    }

    /// "Selesaikan" doesn't stretch the meeting over the night: it ends where
    /// recording stopped.
    @Test func finishingAfterALongSleepEndsWhereRecordingStopped() async throws {
        let session = makeSession(FakeSpeech(meeting: [.final("Halo", 1, 2)]))
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        let startedAt = try #require(session.meeting?.startedAt)
        meetingCapture.send()
        #expect(await waitUntil { session.transcript.lines.count == 1 })
        clock.advance(60)
        session.handleWillSleep()
        clock.advance(14 * 3600)
        await session.handleDidWake()
        #expect(session.wakeQuestion != nil)

        await session.answerWake(continueRecording: false)
        #expect(session.phase == .idle && session.wakeQuestion == nil)
        #expect(!meetingCapture.isCapturing && !micCapture.isCapturing)
        #expect(!power.preventsSleep)
        let saved = try #require(makeStore().meetings.first)
        #expect(saved.status == .ready)
        #expect(saved.endedAt == startedAt.addingTimeInterval(60))
        #expect(saved.gaps.isEmpty)
        #expect(try journal(saved).map(\.text) == ["Halo"])
    }

    /// Two wake reports while capture is still draining from the sleep
    /// restart it once.
    @Test func repeatedWakeRestartsCaptureOnce() async throws {
        let session = makeSession(FakeSpeech(startDelay: .milliseconds(200)))
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        session.handleWillSleep()
        clock.advance(60)
        async let first: Void = session.handleDidWake()
        async let second: Void = session.handleDidWake()
        _ = await (first, second)

        #expect(await waitUntil { meetingCapture.isCapturing && micCapture.isCapturing })
        try await Task.sleep(for: .milliseconds(100))
        #expect(deviceRequests == 2)
        #expect(session.meeting?.gaps.count == 1)
        _ = await session.stop()
    }

    /// The system's sleep and wake reach the session through its `PowerGuard`.
    @Test func sleepAndWakeNotificationsReachTheSession() async throws {
        let center = NotificationCenter()
        let session = makeSession(power: .fake(notifications: center))
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        clock.advance(60)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(await waitUntil { !meetingCapture.isCapturing && !micCapture.isCapturing })
        clock.advance(60)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await waitUntil { meetingCapture.isCapturing && micCapture.isCapturing })
        #expect(session.meeting?.gaps == [Gap(span: .init(start: 60, end: 120), reason: .sleep)])
        _ = await session.stop()
    }

    /// The Mac sleeping again before its wake was handled: nothing restarts
    /// as it goes back to sleep, and the next wake gaps from the first sleep.
    @Test func sleepingAgainBeforeTheWakeIsHandledWaitsForTheNextWake() async throws {
        // Capture stopped for sleep drains for about 400 ms.
        let session = makeSession(FakeSpeech(startDelay: .milliseconds(400)))
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        clock.advance(60)
        session.handleWillSleep()
        clock.advance(60)
        async let firstWake: Void = session.handleDidWake()
        // Let the first wake start waiting for the drain, then sleep again.
        try await Task.sleep(for: .milliseconds(50))
        session.handleWillSleep()
        await firstWake

        try await Task.sleep(for: .milliseconds(100))
        #expect(!meetingCapture.isCapturing && !micCapture.isCapturing)
        #expect(session.meeting?.gaps == [])
        #expect(deviceRequests == 1)
        clock.advance(60)
        await session.handleDidWake()
        #expect(session.meeting?.gaps == [Gap(span: .init(start: 60, end: 180), reason: .sleep)])
        #expect(await waitUntil { meetingCapture.isCapturing && micCapture.isCapturing })
        _ = await session.stop()
    }

    /// Lanjutkan clicked as the Mac goes back to sleep doesn't record
    /// through that sleep; its wake asks again, from the first sleep.
    @Test func continuingAsTheMacSleepsAgainWaitsForItsWake() async throws {
        let session = makeSession()
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        clock.advance(60)
        session.handleWillSleep()
        clock.advance(20 * 60)
        await session.handleDidWake()
        #expect(session.wakeQuestion == 1_200.0)
        session.handleWillSleep()
        await session.answerWake(continueRecording: true)

        try await Task.sleep(for: .milliseconds(100))
        #expect(!meetingCapture.isCapturing && session.meeting?.gaps == [])
        clock.advance(10 * 60)
        await session.handleDidWake()
        #expect(session.wakeQuestion == 1_800.0)
        await session.answerWake(continueRecording: true)
        #expect(session.meeting?.gaps == [Gap(span: .init(start: 60, end: 1_860), reason: .sleep)])
        #expect(await waitUntil { meetingCapture.isCapturing })
        _ = await session.stop()
    }

    /// Capture that can't start after a wake leaves the meeting to resume
    /// or finish at the next launch, and lets the Mac sleep.
    @Test func failedRestartAfterWakeLeavesTheMeetingInterrupted() async throws {
        let session = makeSession()
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        #expect(power.preventsSleep)
        clock.advance(60)
        session.handleWillSleep()
        meetingCapture.startError = ProcessTapCapture.Failure.unsupportedFormat
        micCapture.startError = MicCapture.Failure.noInputDevice
        clock.advance(60)
        await session.handleDidWake()

        #expect(await waitUntil { session.phase == .idle })
        #expect(!power.preventsSleep)
        let saved = try #require(makeStore().meetings.first)
        #expect(saved.status == .interrupted && saved.endedAt == nil && saved.gaps.isEmpty)
        #expect(store.lastError?.hasPrefix("Rekaman tidak bisa dilanjutkan: ") == true)
        #expect(makeStore().recoverInterrupted().map(\.id) == [saved.id])
    }

    // MARK: Meeting ended?

    @Test func offersToFinishWhenTheMeetingAppQuits() async throws {
        let session = makeSession()
        try session.begin(zoomConfig)
        #expect(await waitUntil { session.phase == .recording })
        session.checkMeeting()
        #expect(!session.offersFinish)
        appIsRunning = false
        session.checkMeeting()
        #expect(session.offersFinish)

        clock.advance(30)
        session.declineFinishOffer()
        #expect(!session.offersFinish)
        session.checkMeeting()
        #expect(!session.offersFinish)
        clock.advance(MeetingEndDetector.silenceLimit)
        session.checkMeeting()
        #expect(session.offersFinish)
        // The offer never stops the recording itself.
        #expect(session.phase == .recording && meetingCapture.isCapturing)
        _ = await session.stop()
        #expect(!session.offersFinish)
    }

    /// System-wide audio has no app to quit; ten quiet minutes count from
    /// the last sound.
    @Test func quietMeetingAudioOffersToFinish() async throws {
        appIsRunning = false
        let session = makeSession()
        try session.begin(config)
        #expect(await waitUntil { session.phase == .recording })
        clock.advance(30)
        session.checkMeeting()
        #expect(!session.offersFinish)
        #expect(session.notices == [.silent])

        clock.advance(270)
        meetingCapture.send()
        // The silence notice goes once the session heard the sound, at 300.
        #expect(await waitUntil { session.notices.isEmpty })
        clock.advance(599)
        session.checkMeeting()
        #expect(!session.offersFinish)
        clock.advance(1)
        session.checkMeeting()
        #expect(session.offersFinish)
        _ = await session.stop()
    }

    /// The recorded app's bundle ID may never show up as a running app (a
    /// helper process's own ID), so the app counts as quit only once it was
    /// seen running.
    @Test func appNeverSeenRunningIsNotOfferedAsQuit() async throws {
        appIsRunning = false
        let session = makeSession()
        try session.begin(zoomConfig)
        #expect(await waitUntil { session.phase == .recording })
        session.checkMeeting()
        clock.advance(30)
        session.checkMeeting()
        #expect(!session.offersFinish)
        appIsRunning = true
        session.checkMeeting()
        #expect(!session.offersFinish)
        appIsRunning = false
        session.checkMeeting()
        #expect(session.offersFinish)
        _ = await session.stop()
    }

    /// An app that quits while a quiet offer is showing is covered by the
    /// owner's Tetap merekam: the next offer waits another ten quiet minutes.
    @Test func appQuitDuringAShownOfferIsCoveredByTheDecline() async throws {
        let session = makeSession()
        try session.begin(zoomConfig)
        #expect(await waitUntil { session.phase == .recording })
        session.checkMeeting()
        clock.advance(MeetingEndDetector.silenceLimit)
        session.checkMeeting()
        #expect(session.offersFinish)
        appIsRunning = false
        session.checkMeeting()
        clock.advance(30)
        session.declineFinishOffer()

        session.checkMeeting()
        #expect(!session.offersFinish)
        clock.advance(599)
        session.checkMeeting()
        #expect(!session.offersFinish)
        clock.advance(1)
        session.checkMeeting()
        #expect(session.offersFinish)
        _ = await session.stop()
    }

    /// A declined app-quit offer stays declined across a short sleep; the
    /// wake restarts only the quiet clock.
    @Test func declinedAppQuitStaysDeclinedAfterAShortSleep() async throws {
        let session = makeSession()
        try session.begin(zoomConfig)
        #expect(await waitUntil { session.phase == .recording })
        session.checkMeeting()
        appIsRunning = false
        session.checkMeeting()
        #expect(session.offersFinish)
        clock.advance(30)
        session.declineFinishOffer()
        session.handleWillSleep()
        clock.advance(5 * 60)
        await session.handleDidWake()
        #expect(await waitUntil { meetingCapture.isCapturing })

        session.checkMeeting()
        #expect(!session.offersFinish)
        clock.advance(599)
        session.checkMeeting()
        #expect(!session.offersFinish)
        // Ten quiet minutes from the wake.
        clock.advance(1)
        session.checkMeeting()
        #expect(session.offersFinish)
        _ = await session.stop()
    }
}
