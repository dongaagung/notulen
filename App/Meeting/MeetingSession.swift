import AppKit
import AVFoundation
import Foundation
import Observation
import Synchronization

/// Records one meeting at a time: captures the meeting audio and the mic,
/// transcribes both on device and journals every final line. The meeting
/// audio is also kept in RAM (16 kHz mono) for speaker separation.
/// Keeps the Mac from idle-sleeping meanwhile; if it sleeps anyway, capture
/// stops and the sleep becomes a gap. Offers to finish once the meeting
/// looks over.
@MainActor
@Observable
final class MeetingSession {
    enum Phase: Equatable {
        case idle, starting, recording, stopping
    }

    enum StartError: LocalizedError, Equatable {
        case alreadyRecording
        /// Application Support can't be opened, so the transcript couldn't be saved.
        case noStorage

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: "Meeting lain masih direkam. Selesaikan dulu."
            case .noStorage: "Folder data Notulen tidak bisa dibuka, jadi transkrip tidak bisa disimpan."
            }
        }
    }

    struct Configuration {
        var title: String
        var audioSource: MeetingAudioSource
        var locale: Locale
        /// Terms to recognize on top of the built-in ones.
        var vocabulary: [String]
    }

    private(set) var phase = Phase.idle
    /// The meeting being recorded, or the last one once it stopped.
    private(set) var meeting: Meeting?
    private(set) var transcript = Transcript()
    /// Problems worth telling the owner about; recording may still go on.
    private(set) var notices: [MeetingNotice] = []
    /// What a slow start is doing, such as downloading the speech model.
    private(set) var startupStatus: String?
    /// How long the Mac slept, while the owner is asked whether to record on.
    /// Nothing records until `answerWake(continueRecording:)`.
    private(set) var wakeQuestion: TimeInterval?
    /// Writes the live notes while recording; nil without a usable AI
    /// provider (the live view then shows `store.aiProblem`).
    private(set) var liveNotes: LiveNotesUpdater?
    /// The meeting looks over: offer to finish it. Recording goes on.
    private(set) var offersFinish = false
    /// The meeting audio's loudest sample over the last tenth of a second,
    /// from 0 to 1, for the level meter. 0 while it isn't captured.
    private(set) var level: Float = 0
    /// The input device the mic records from, once known.
    private(set) var micName: String?
    /// When the owner had the mic off. The meeting audio records on meanwhile.
    private var micOff = MicOffTracker()

    /// Recording time so far; 0 until capture starts.
    var elapsed: TimeInterval {
        phase == .recording || phase == .stopping ? meetingTime : 0
    }

    /// Meeting audio still silent this long after capture starts raises `.silent`.
    static let silenceDelay: TimeInterval = 20
    /// How often `level` changes at most.
    nonisolated static let levelInterval = Duration.milliseconds(100)

    private let store: AppStore
    private let makeDevices: @MainActor (MeetingAudioSource) -> CaptureDevices
    private let makeSpeech: @Sendable (Locale, [String]) -> any SttProvider
    private let now: () -> Date
    private let makeAudioBuffer: () -> MeetingAudioBuffer
    /// Whether the app with this bundle ID runs.
    private let appRunning: @MainActor (String) -> Bool
    private let power: PowerGuard

    /// What the meeting records with; a wake starts capture with it again.
    private var configuration: Configuration?
    private var devices: CaptureDevices?
    private var journal: TranscriptJournal?
    /// The meeting channel as 16 kHz mono, for speaker separation.
    private var meetingAudio = MeetingAudioBuffer()
    /// Meeting time at which each channel's current speech stream started.
    /// Recognizer spans count from there; each listener keeps its own, as
    /// the mic's last lines from before it went off can come in after it's
    /// back on.
    private var offsets: [Channel: TimeInterval] = [:]
    private var startTask: Task<Void, Never>?
    private var listeners: [Task<Void, Never>] = []
    /// Pass each channel's audio on to speech; the meeting's relay (the tee)
    /// is also the only writer of `meetingAudio`.
    private var relays: [Task<Void, Never>] = []
    private var monitorTask: Task<Void, Never>?
    /// The recognizer for the mic while it may record (it may be off);
    /// turning it on starts a new speech stream with it.
    private var micSpeech: (any SttProvider)?
    /// The mic's audio on its way to speech, while its capture runs.
    private var micFeed: MicSpeechFeed?
    /// Why the mic couldn't come back on, until it does.
    private var micOnFailure: MeetingNotice?
    private var capturesMeeting = false
    private var heardMeeting = false
    /// Tells when the meeting looks over, for the offer to finish. Made
    /// when the meeting audio first starts, and kept for the whole meeting so
    /// a declined offer stays declined across a wake.
    private var endDetector: MeetingEndDetector?
    /// The one app the meeting records was seen running. Only then does its
    /// absence mean it quit: a helper process's own bundle ID may never
    /// show up as a running app.
    private var appSeenRunning = false
    /// Meeting time the Mac went to sleep at, until recording goes on.
    private var sleptAt: TimeInterval?
    /// Between the Mac going to sleep and its next wake. It can sleep again
    /// before the last wake was handled.
    private var asleep = false
    /// The last lines coming in after capture stopped for sleep.
    private var sleepDrain: Task<Void, Never>?

    init(
        store: AppStore,
        devices: @escaping @MainActor (MeetingAudioSource) -> CaptureDevices = CaptureDevices.live,
        speech: @escaping @Sendable (Locale, [String]) -> any SttProvider = {
            SpeechAnalyzerProvider(locale: $0, vocabulary: $1)
        },
        now: @escaping () -> Date = Date.init,
        audioBuffer: @escaping () -> MeetingAudioBuffer = { MeetingAudioBuffer() },
        appRunning: @escaping @MainActor (String) -> Bool = {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        },
        power: PowerGuard = PowerGuard()
    ) {
        self.store = store
        self.makeDevices = devices
        self.makeSpeech = speech
        self.now = now
        self.makeAudioBuffer = audioBuffer
        self.appRunning = appRunning
        self.power = power
        power.onWillSleep = { [weak self] in self?.handleWillSleep() }
        power.onDidWake = { [weak self] in
            Task { [weak self] in await self?.handleDidWake() }
        }
    }

    // MARK: Lifecycle

    /// Creates and saves the meeting and opens its journal, then starts in
    /// the background so the start can be cancelled while the speech model
    /// downloads.
    func begin(_ configuration: Configuration) throws {
        guard phase == .idle else { throw StartError.alreadyRecording }
        let meeting = Meeting(
            title: configuration.title.trimmingCharacters(in: .whitespacesAndNewlines),
            startedAt: now(), status: .recording,
            language: configuration.locale.identifier(.bcp47),
            audioSource: configuration.audioSource)
        guard let journalURL = store.transcriptURL(for: meeting.id) else { throw StartError.noStorage }
        store.save(meeting)
        let journal: TranscriptJournal
        do {
            journal = try TranscriptJournal(url: journalURL)
        } catch {
            store.delete(meeting)
            throw error
        }
        take(meeting, journal: journal, transcript: Transcript(), configuration: configuration)
        phase = .starting
        startTask = Task { await start(configuration, resumedAfter: nil) }
    }

    /// Records on in a meeting a crash or quit cut off: its journaled lines
    /// come back, and the time since the recording stopped is a crash gap.
    /// Meeting time runs from the original start, so the meeting counts as
    /// recording at once; capture restarts in the background. If it can't,
    /// the meeting goes back to interrupted.
    func resume(_ meeting: Meeting) throws {
        guard phase == .idle else { throw StartError.alreadyRecording }
        guard let journalURL = store.transcriptURL(for: meeting.id) else { throw StartError.noStorage }
        let lines = try store.transcriptLines(for: meeting.id)
        let journal = try TranscriptJournal(url: journalURL)
        var meeting = meeting
        let stoppedAt = meeting.recordedUntil(lines)
        let resumedAt = now().timeIntervalSince(meeting.startedAt)
        let gap = Gap(span: TimeSpan(start: stoppedAt, end: max(stoppedAt, resumedAt)), reason: .crash)
        meeting.gaps.append(gap)
        meeting.status = .recording
        meeting.endedAt = nil
        store.save(meeting)
        let configuration = Configuration(
            title: meeting.title, audioSource: meeting.audioSource,
            locale: Locale(identifier: meeting.language), vocabulary: store.settings.vocabulary)
        take(meeting, journal: journal, transcript: Transcript(lines: lines), configuration: configuration)
        phase = .recording
        startTask = Task { await start(configuration, resumedAfter: gap) }
    }

    /// Ends a meeting a crash or quit cut off, where its recording stopped.
    /// Task 17 routes it to the finisher.
    func finishInterrupted(_ meeting: Meeting) async {
        guard meeting.id != self.meeting?.id || phase == .idle else { return }
        var meeting = meeting
        let lines = (try? store.transcriptLines(for: meeting.id)) ?? []
        meeting.endedAt = meeting.startedAt.addingTimeInterval(meeting.recordedUntil(lines))
        meeting.status = .ready
        store.save(meeting)
    }

    /// Starts over with `meeting`, whose final lines go to `journal`.
    private func take(
        _ meeting: Meeting, journal: TranscriptJournal, transcript: Transcript, configuration: Configuration
    ) {
        self.meeting = meeting
        self.journal = journal
        self.transcript = transcript
        self.configuration = configuration
        notices = []
        offsets = [:]
        micOff = MicOffTracker(spans: meeting.micOff)
        micOnFailure = nil
        micName = nil
        meetingAudio = makeAudioBuffer()
        capturesMeeting = false
        heardMeeting = false
        startupStatus = "Menyiapkan pengenalan suara…"
        resetSleepAndOffers()
    }

    /// Stops a start that is still getting ready, such as downloading the
    /// speech model, and removes the meeting: nothing was recorded yet.
    func cancelStart() {
        guard phase == .starting else { return }
        startTask?.cancel()
        startTask = nil
        discardCapture()
        if let meeting { store.delete(meeting) }
        meeting = nil
        startupStatus = nil
        phase = .idle
    }

    /// `gap`: the gap a resume or a wake added. A resumed meeting keeps its
    /// start time; it is already recording.
    private func start(_ configuration: Configuration, resumedAfter gap: Gap?) async {
        let speech = makeSpeech(configuration.locale, configuration.vocabulary)
        do {
            // Downloads the on-device speech model on first use.
            try await speech.prepare { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, startupStatus != nil else { return }
                    startupStatus = "Mengunduh model bahasa… \(Int(fraction * 100))%"
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            let message = "Pengenalan suara tidak bisa disiapkan: \(error.localizedDescription)"
            post(.error(message))
            failStart(message, resumedAfter: gap)
            return
        }
        guard !Task.isCancelled else { return }

        startupStatus = "Memulai rekaman…"
        let devices = makeDevices(configuration.audioSource)
        self.devices = devices
        let micAllowed = await type(of: devices.mic).requestPermission()
        guard !Task.isCancelled else { return }

        if gap == nil {
            // Meeting time 0 is when capture starts, not when the start began.
            meeting?.startedAt = now()
            if let meeting { store.save(meeting) }
        }
        startCapture(devices, micAllowed: micAllowed, speech: speech)
        startupStatus = nil
        guard !listeners.isEmpty else {
            failStart(notices.map(\.message).joined(separator: "\n"), resumedAfter: gap)
            return
        }
        watchOutputRoute(devices.output)
        phase = .recording
        power.begin()
        startLiveNotes()
        startMonitoring()
    }

    /// Stops capture, waits up to 3 s for the last lines, and closes the
    /// meeting. Nil unless a meeting is recording.
    func stop() async -> Meeting? {
        await endRecording(as: .ready)
    }

    /// Stops recording without ending the meeting, as when the owner quits:
    /// it's saved as interrupted, to resume or finish at the next launch.
    func interrupt() async {
        _ = await endRecording(as: .interrupted)
    }

    /// Stops capture, waits up to 3 s for the last lines, then saves the
    /// meeting as `status` and lets go of its journal and audio.
    private func endRecording(as status: MeetingStatus) async -> Meeting? {
        guard phase == .recording else { return nil }
        phase = .stopping
        wakeQuestion = nil
        offersFinish = false
        liveNotes?.stop()
        haltCapture()
        // Capture that stopped for sleep may still be draining.
        await sleepDrain?.value
        sleepDrain = nil
        await drainCapture()
        meeting?.status = status
        // An interrupted meeting goes on later. One stopped while the Mac
        // slept, or before the owner answered after it woke, ended when its
        // recording did, not the next morning.
        if status != .interrupted, let startedAt = meeting?.startedAt {
            meeting?.endedAt = sleptAt.map { startedAt.addingTimeInterval($0) } ?? now()
        }
        closeMicOff(at: sleptAt ?? meetingTime)
        resetSleepAndOffers()
        if let meeting { store.save(meeting) }
        journal?.close()
        journal = nil
        liveNotes = nil
        notices.removeAll { $0 == .liveNotesDelayed }
        power.end()
        // Task 17 hands the buffer to the finisher instead.
        meetingAudio.wipe()
        phase = .idle
        return meeting
    }

    /// Stops capture and the work around it at once; `drainCapture()` then
    /// collects the last lines.
    private func haltCapture() {
        // A resumed or woken meeting may still be getting capture ready.
        startTask?.cancel()
        startTask = nil
        startupStatus = nil
        monitorTask?.cancel()
        monitorTask = nil
        stopCapture()
    }

    /// Once capture stopped: waits up to 3 s for the last lines, then for
    /// the relays. The meeting stays as it is.
    private func drainCapture() async {
        await finishListeners(within: .seconds(3))
        // The relays end with the capture streams; nothing may write to the
        // buffer once it's wiped.
        let pending = relays
        relays = []
        pending.forEach { $0.cancel() }
        for relay in pending { await relay.value }
        transcript.discardVolatile(.meeting)
        transcript.discardVolatile(.mic)
    }

    /// Nothing could be recorded. A new meeting is saved as failed, with why.
    /// A resumed or woken one goes back to interrupted without the gap the
    /// resume or wake added, to resume or finish later, and the owner hears
    /// why in the error bar (the live view is gone by then).
    private func failStart(_ message: String, resumedAfter gap: Gap?) {
        discardCapture()
        resetSleepAndOffers()
        if let gap {
            if let index = meeting?.gaps.lastIndex(of: gap) { meeting?.gaps.remove(at: index) }
            // Recording stopped where the gap starts; so did a mic left off.
            closeMicOff(at: gap.span.start)
            meeting?.status = .interrupted
            store.lastError = "Rekaman tidak bisa dilanjutkan: \(message)"
        } else {
            meeting?.status = .failed
            meeting?.failure = message
            meeting?.endedAt = now()
        }
        if let meeting { store.save(meeting) }
        startupStatus = nil
        phase = .idle
    }

    /// Lets go of what a start set up. The relays only run once recording,
    /// so the buffer can be wiped here.
    private func discardCapture() {
        assert(relays.isEmpty)
        stopCapture()
        listeners.forEach { $0.cancel() }
        listeners = []
        journal?.close()
        journal = nil
        power.end()
        meetingAudio.wipe()
    }

    private func stopCapture() {
        devices?.meeting.stop()
        devices?.mic.stop()
        devices?.output.stop()
        devices = nil
        micSpeech = nil
        micFeed = nil
        level = 0
    }

    // MARK: Pipeline

    /// Starts both channels. A channel that can't start is reported, and the
    /// other records on its own.
    private func startCapture(_ devices: CaptureDevices, micAllowed: Bool, speech: any SttProvider) {
        reportDeviceChanges(of: devices)
        capturesMeeting = false
        do {
            let stream = try devices.meeting.start()
            let offset = meetingTime
            capturesMeeting = true
            // Quiet counts from when the meeting audio started, also after a
            // wake; what was offered or declined carries over.
            if endDetector == nil {
                endDetector = MeetingEndDetector(startedAt: offset)
            } else {
                endDetector?.restartQuietClock(at: offset)
            }
            meetingAudio.beginSegment(atMeetingTime: offset)
            listen(to: tee(stream, into: meetingAudio), channel: .meeting, from: offset, with: speech)
        } catch {
            post(.error(error.localizedDescription))
        }
        guard micAllowed else {
            post(.error(MicCapture.Failure.permissionDenied.localizedDescription))
            return
        }
        micSpeech = speech
        // Turned off before a sleep or while capture restarted: the mic stays
        // closed until the owner turns it on.
        guard isMicOn else { return }
        do {
            try startMic()
        } catch {
            post(.error(error.localizedDescription))
        }
    }

    /// Opens the mic and feeds it to a new speech stream counting from now.
    private func startMic() throws {
        guard let devices, let micSpeech else { return }
        let capture = try devices.mic.start()
        micName = devices.mic.deviceName ?? micName
        let feed = MicSpeechFeed()
        // Before the relay runs, so its first chunks have a stream to go to.
        let audio = feed.next()
        relay(capture, into: feed)
        micFeed = feed
        listen(to: audio, channel: .mic, from: meetingTime, with: micSpeech)
    }

    /// A device that can't be restarted mid-meeting stops its channel only.
    /// The owner hears when the mic or the meeting's output moved.
    private func reportDeviceChanges(of devices: CaptureDevices) {
        if let tap = devices.meeting as? ProcessTapCapture {
            tap.onReattachFailure = { [weak self] error in
                self?.post(.error("Audio meeting berhenti terekam: \(error.localizedDescription)"))
            }
            tap.onOutputChanged = { [weak self] in self?.checkOutputRoute() }
        }
        if let mic = devices.mic as? MicCapture {
            mic.onRestartFailure = { [weak self] error in
                self?.post(.error("Mic berhenti merekam: \(error.localizedDescription)"))
            }
        }
        devices.mic.onDeviceChange = { [weak self] name in self?.micDeviceChanged(to: name) }
    }

    // The recognizer reads nothing for a few seconds while its analyzer
    // starts, and a capture keeps only its newest 128 chunks (about 1.4 s of
    // tap audio). A chunk dropped then never reaches speech, so every later
    // line of that channel would come out early, and meeting lines would no
    // longer match `meetingAudio` for speaker separation. So the relays read
    // the captures at once and hold whatever speech hasn't read yet, without
    // a limit: about 384 KB per second of lag for 48 kHz stereo, and nothing
    // once speech has stopped reading (its stream is gone then).

    /// Passes the mic audio on to speech without dropping any, except while
    /// the mic is off.
    private func relay(_ audio: AsyncStream<AudioChunk>, into feed: MicSpeechFeed) {
        relays.append(Task.detached {
            for await chunk in audio { feed.yield(chunk) }
            feed.end()
        })
    }

    /// Passes the meeting audio on to speech without dropping any, and keeps
    /// a 16 kHz mono copy in `buffer`, off the main actor. Notes, at most
    /// every 2 s, that the meeting isn't silent, and sets `level` at most
    /// every `levelInterval`. Reports once if the copy fails or reaches the
    /// buffer's cap.
    private func tee(_ audio: AsyncStream<AudioChunk>, into buffer: MeetingAudioBuffer) -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        relays.append(Task.detached { [weak self] in
            var converter = AudioConverter(target: .mono16kInt16)
            var lastHeard = ContinuousClock.now - .seconds(10)
            var isFull = false
            var conversionFailed = false
            // The loudest sample since `level` was last set.
            var loudest: Float = 0
            var levelSetAt = ContinuousClock.now - MeetingSession.levelInterval
            for await chunk in audio {
                continuation.yield(chunk)
                if !isFull {
                    do {
                        if !buffer.append(try converter.convert(chunk.buffer)) {
                            isFull = true
                            Task { @MainActor [weak self] in self?.post(.speakerAudioFull) }
                        }
                    } catch {
                        if !conversionFailed {
                            conversionFailed = true
                            Task { @MainActor [weak self] in self?.post(.speakerAudioFailed) }
                        }
                    }
                }
                let peak = chunk.buffer.peakLevel
                if peak > AVAudioPCMBuffer.silenceThreshold, ContinuousClock.now - lastHeard > .seconds(2) {
                    lastHeard = .now
                    Task { @MainActor [weak self] in self?.heardMeetingAudio() }
                }
                loudest = max(loudest, peak)
                if ContinuousClock.now - levelSetAt >= MeetingSession.levelInterval {
                    levelSetAt = .now
                    let level = loudest
                    loudest = 0
                    Task { @MainActor [weak self] in self?.show(level: level) }
                }
            }
            continuation.finish()
        })
        return stream
    }

    /// `offset`: meeting time at which `audio` starts.
    private func listen(
        to audio: AsyncStream<AudioChunk>, channel: Channel, from offset: TimeInterval, with speech: any SttProvider
    ) {
        offsets[channel] = offset
        listeners.append(Task { [weak self] in
            do {
                for try await update in speech.transcribe(audio) {
                    self?.handle(update, from: channel, offset: offset)
                }
            } catch {
                guard !Task.isCancelled else { return }
                let name = channel == .mic ? "mic" : "meeting"
                self?.post(.error("Transkrip \(name) berhenti: \(error.localizedDescription)"))
            }
        })
    }

    private func finishListeners(within timeout: Duration) async {
        let pending = listeners
        listeners = []
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            pending.forEach { $0.cancel() }
        }
        for listener in pending { await listener.value }
        deadline.cancel()
    }

    /// Adds the update to the transcript and journals the line it finalizes.
    /// `offset`: meeting time at which its speech stream started. A mic line
    /// that repeats what the meeting just said is the speakers' echo and is
    /// dropped.
    private func handle(_ update: TranscriptUpdate, from channel: Channel, offset: TimeInterval) {
        let time = meetingTime
        if channel == .mic, update.isFinal {
            let start = update.span.map { offset + $0.start } ?? time
            if EchoFilter.isLikelyEcho(update.text, at: start, recent: transcript.lines) {
                transcript.discardVolatile(.mic)
                return
            }
        }
        guard let line = transcript.apply(update, channel: channel, offset: offset, now: time) else { return }
        do {
            try journal?.append(line)
        } catch {
            post(.error("Transkrip tidak bisa disimpan: \(error.localizedDescription)"))
        }
        liveNotes?.add(line)
    }

    // MARK: Sleep

    /// The Mac is about to sleep: capture stops at once. The meeting stays
    /// recording with its journal open; waking decides what comes next.
    /// `PowerGuard` calls it; internal for tests.
    func handleWillSleep() {
        guard phase == .recording else { return }
        asleep = true
        // Capture is stopped already: the Mac sleeps again before its last
        // wake was handled, or while the owner is asked. The gap keeps the
        // first sleep's start.
        guard sleptAt == nil else { return }
        sleptAt = meetingTime
        haltCapture()
        sleepDrain = Task { await drainCapture() }
    }

    /// After a short sleep recording goes on by itself, with the sleep as a
    /// gap. After a long one nothing records until the owner answers
    /// `wakeQuestion`. `PowerGuard` calls it; internal for tests.
    func handleDidWake() async {
        asleep = false
        guard phase == .recording, let sleptAt, wakeQuestion == nil else { return }
        await sleepDrain?.value
        sleepDrain = nil
        // Meanwhile the Mac may have gone back to sleep (its next wake
        // decides), another wake report may have handled it, or Selesai or
        // quitting ended the meeting.
        guard phase == .recording, !asleep, self.sleptAt == sleptAt, wakeQuestion == nil else { return }
        let slept = meetingTime - sleptAt
        switch WakePolicy.decision(sleptFor: slept) {
        case .resume:
            recordAfterSleep()
            notices.removeAll { if case .resumedAfterSleep = $0 { true } else { false } }
            post(.resumedAfterSleep(slept))
        case .ask:
            // The question offers to finish too.
            offersFinish = false
            wakeQuestion = slept
            NSApp?.activate()
        }
    }

    /// The owner's answer after a long sleep: record on, with the sleep as a
    /// gap that ends now, or finish the meeting where its recording stopped.
    func answerWake(continueRecording: Bool) async {
        guard phase == .recording, wakeQuestion != nil else { return }
        wakeQuestion = nil
        if !continueRecording {
            _ = await stop()
        } else if !asleep {
            recordAfterSleep()
        }
        // Lanjutkan as the Mac goes back to sleep: its wake decides again,
        // from the first sleep's start.
    }

    /// Saves the sleep as a gap that ends now and starts capture again the
    /// way a resume does: new offsets and a new buffer segment from now, the
    /// same journal. If capture can't start, the meeting goes back to
    /// interrupted.
    private func recordAfterSleep() {
        guard let sleptAt, let configuration else { return }
        self.sleptAt = nil
        let gap = Gap(span: TimeSpan(start: sleptAt, end: max(sleptAt, meetingTime)), reason: .sleep)
        meeting?.gaps.append(gap)
        if let meeting { store.save(meeting) }
        startTask = Task { await start(configuration, resumedAfter: gap) }
    }

    private func resetSleepAndOffers() {
        sleptAt = nil
        asleep = false
        sleepDrain = nil
        wakeQuestion = nil
        offersFinish = false
        endDetector = nil
        appSeenRunning = false
    }

    // MARK: Background work

    /// Every 10 s while recording.
    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled, phase == .recording else { return }
                checkMeeting()
                await updateLiveNotes()
            }
        }
    }

    /// Makes the live notes updater once the meeting records, if an AI
    /// provider is ready. A wake or resume keeps the one it has.
    private func startLiveNotes() {
        guard liveNotes == nil, let snapshot = meeting, let client = store.aiClient() else { return }
        let template: PromptTemplate
        do {
            template = try PromptTemplate.load("live_notes")
        } catch {
            post(.error(error.localizedDescription))
            return
        }
        let updater = LiveNotesUpdater(
            client: client, template: template, meeting: { [weak self] in self?.meeting ?? snapshot },
            start: now())
        updater.onUpdate = { [weak self] notes, date in
            guard let self else { return }
            meeting?.liveNotes = notes
            meeting?.liveNotesUpdatedAt = date
            if let meeting { store.save(meeting) }
        }
        updater.onError = { [weak self] in self?.post(.error($0)) }
        liveNotes = updater
    }

    /// Asks the live notes for an update when one is due; internal for tests.
    /// Not while the Mac sleeps or the owner is asked what to do after it.
    func updateLiveNotes() async {
        guard phase == .recording, sleptAt == nil, !asleep, let liveNotes else { return }
        await liveNotes.updateIfDue(now: now())
        guard phase == .recording, self.liveNotes === liveNotes else { return }
        if liveNotes.isDelayed {
            post(.liveNotesDelayed)
        } else {
            notices.removeAll { $0 == .liveNotesDelayed }
        }
    }

    /// Warns if the meeting is silent, and offers to finish once it looks
    /// over. Runs every 10 s while recording; internal for tests.
    func checkMeeting() {
        // Nothing records while the Mac sleeps or the owner is asked.
        guard sleptAt == nil else { return }
        warnIfMeetingSilent()
        offerFinishIfOver()
    }

    /// The owner chose Tetap merekam: the next offer comes after another
    /// 10 quiet minutes.
    func declineFinishOffer() {
        guard offersFinish else { return }
        offersFinish = false
        // Covers an app that quit while the offer was showing.
        endDetector?.declined(at: meetingTime, appRunning: meetingAppRunning())
    }

    /// Offers, never stops: the meeting audio has been quiet for 10 minutes,
    /// or the one app it records quit. Not without meeting audio, as when
    /// its capture couldn't start: a mic-only recording isn't "over".
    private func offerFinishIfOver() {
        guard !offersFinish, capturesMeeting, var detector = endDetector else { return }
        offersFinish = detector.shouldOffer(at: meetingTime, appRunning: meetingAppRunning())
        endDetector = detector
    }

    /// False once the one app the meeting records quit, after it was seen
    /// running. System-wide audio has no app to quit.
    private func meetingAppRunning() -> Bool {
        guard case .app(let bundleID, _)? = meeting?.audioSource else { return true }
        let running = appRunning(bundleID)
        if running { appSeenRunning = true }
        return running || !appSeenRunning
    }

    /// Counts from when the meeting channel started, which is late in a
    /// resumed meeting.
    private func warnIfMeetingSilent() {
        guard capturesMeeting, !heardMeeting, meetingTime - (offsets[.meeting] ?? 0) > Self.silenceDelay
        else { return }
        post(.silent)
    }

    /// Not from a capture that has stopped: its last chunks can come late.
    private func show(level: Float) {
        guard devices != nil, level != self.level else { return }
        self.level = level
    }

    private func heardMeetingAudio() {
        heardMeeting = true
        notices.removeAll { $0 == .silent }
        endDetector?.heardSound(at: meetingTime)
    }

    // MARK: Devices

    /// Only the latest move is worth showing.
    private func micDeviceChanged(to name: String) {
        micName = name
        notices.removeAll { if case .micChanged = $0 { true } else { false } }
        post(.micChanged(name))
    }

    /// Checks the route now and whenever it changes, until capture stops.
    private func watchOutputRoute(_ route: any OutputRouteMonitoring) {
        route.onChange = { [weak self] in self?.checkOutputRoute() }
        route.start()
        checkOutputRoute()
    }

    /// Shows `.speakerOutput` while the meeting plays through the Mac's
    /// speakers. While capture is stopped the last answer stands.
    private func checkOutputRoute() {
        guard let route = devices?.output else { return }
        if route.isBuiltInSpeaker {
            post(.speakerOutput)
        } else {
            notices.removeAll { $0 == .speakerOutput }
        }
    }

    private func post(_ notice: MeetingNotice) {
        guard !notices.contains(notice) else { return }
        notices.append(notice)
    }

    /// Seconds since the meeting started.
    private var meetingTime: TimeInterval {
        guard let meeting else { return 0 }
        return now().timeIntervalSince(meeting.startedAt)
    }
}

// MARK: Mic

extension MeetingSession {
    /// False while the owner has the mic off.
    var isMicOn: Bool { !micOff.isOff }

    /// Turns the owner's mic off or on while recording; does nothing
    /// otherwise. The meeting audio records on either way. Every change is
    /// saved at once, so a crash keeps when the mic went off. A mic that
    /// can't come back on stays off, and the owner hears why.
    func setMicEnabled(_ enabled: Bool) {
        guard phase == .recording, enabled != isMicOn else { return }
        let time = meetingTime
        if enabled {
            guard turnMicOn() else { return }
            micOff.turnOn(at: time)
        } else {
            turnMicOff()
            micOff.turnOff(at: time)
        }
        meeting?.micOff = micOff.spans(through: time)
        if let meeting { store.save(meeting) }
    }

    /// Lets go of the mic and ends its speech stream, so the recognizer
    /// finalizes what was said up to now. Capture that is stopped (the Mac
    /// slept) or not started yet just stays closed.
    private func turnMicOff() {
        guard let micFeed else { return }
        devices?.mic.pause()
        micFeed.end()
    }

    /// Takes the mic again with a new speech stream counting from now: none
    /// of the mic's audio flowed while it was off, so the old stream's times
    /// would lag the meeting by that long. A mic that was never opened (it
    /// was off when capture started) opens now. False if it can't.
    private func turnMicOn() -> Bool {
        if let micOnFailure { notices.removeAll { $0 == micOnFailure } }
        micOnFailure = nil
        do {
            if let micFeed, let micSpeech, let mic = devices?.mic {
                let audio = micFeed.next()
                do {
                    try mic.resume()
                } catch {
                    micFeed.end()
                    throw error
                }
                listen(to: audio, channel: .mic, from: meetingTime, with: micSpeech)
            } else {
                try startMic()
            }
        } catch {
            let notice = MeetingNotice.error("Mic tidak bisa dinyalakan: \(error.localizedDescription)")
            micOnFailure = notice
            post(notice)
            return false
        }
        return true
    }

    /// Ends a mic-off period still going on, as the recording stops at `time`.
    private func closeMicOff(at time: TimeInterval) {
        micOff.close(at: time)
        meeting?.micOff = micOff.spans
    }
}

/// Hands the mic's audio to one speech stream at a time. Turning the mic off
/// ends the current stream; turning it on starts the next, whose times count
/// from then. Audio that comes between two streams is dropped: the mic is off.
private final class MicSpeechFeed: Sendable {
    private let current = Mutex<AsyncStream<AudioChunk>.Continuation?>(nil)

    /// Ends the current stream and starts the next. Unbounded, like the
    /// relays: nothing is dropped while the recognizer starts.
    func next() -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        current.withLock {
            $0?.finish()
            $0 = continuation
        }
        return stream
    }

    func yield(_ chunk: AudioChunk) {
        current.withLock { _ = $0?.yield(chunk) }
    }

    func end() {
        current.withLock {
            $0?.finish()
            $0 = nil
        }
    }
}
