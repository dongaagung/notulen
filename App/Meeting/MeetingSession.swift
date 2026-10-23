import AVFoundation
import Foundation
import Observation

/// Records one meeting at a time: captures the meeting audio and the mic,
/// transcribes both on device and journals every final line. The meeting
/// audio is also kept in RAM (16 kHz mono) for speaker separation.
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

    /// Recording time so far; 0 until capture starts.
    var elapsed: TimeInterval {
        phase == .recording || phase == .stopping ? meetingTime : 0
    }

    /// Meeting audio still silent this long after capture starts raises `.silent`.
    static let silenceDelay: TimeInterval = 20

    private let store: AppStore
    private let makeDevices: @MainActor (MeetingAudioSource) -> CaptureDevices
    private let makeSpeech: @Sendable (Locale, [String]) -> any SttProvider
    private let now: () -> Date
    private let makeAudioBuffer: () -> MeetingAudioBuffer

    private var devices: CaptureDevices?
    private var journal: TranscriptJournal?
    /// The meeting channel as 16 kHz mono, for speaker separation.
    private var meetingAudio = MeetingAudioBuffer()
    /// Meeting time at which each channel's current audio stream started.
    /// Recognizer spans count from there.
    private var offsets: [Channel: TimeInterval] = [:]
    private var startTask: Task<Void, Never>?
    private var listeners: [Task<Void, Never>] = []
    /// Pass each channel's audio on to speech; the meeting's relay (the tee)
    /// is also the only writer of `meetingAudio`.
    private var relays: [Task<Void, Never>] = []
    private var monitorTask: Task<Void, Never>?
    private var capturesMeeting = false
    private var heardMeeting = false

    init(
        store: AppStore,
        devices: @escaping @MainActor (MeetingAudioSource) -> CaptureDevices = CaptureDevices.live,
        speech: @escaping @Sendable (Locale, [String]) -> any SttProvider = {
            SpeechAnalyzerProvider(locale: $0, vocabulary: $1)
        },
        now: @escaping () -> Date = Date.init,
        audioBuffer: @escaping () -> MeetingAudioBuffer = { MeetingAudioBuffer() }
    ) {
        self.store = store
        self.makeDevices = devices
        self.makeSpeech = speech
        self.now = now
        self.makeAudioBuffer = audioBuffer
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
        take(meeting, journal: journal, transcript: Transcript())
        phase = .starting
        startTask = Task { await start(configuration, resuming: false) }
    }

    /// Records on in a meeting a crash or quit cut off: its journaled lines
    /// come back, and the time since the last one is a crash gap. Meeting
    /// time runs from the original start, so the meeting counts as recording
    /// at once; capture restarts in the background.
    func resume(_ meeting: Meeting) throws {
        guard phase == .idle else { throw StartError.alreadyRecording }
        guard let journalURL = store.transcriptURL(for: meeting.id) else { throw StartError.noStorage }
        let lines = try store.transcriptLines(for: meeting.id)
        let journal = try TranscriptJournal(url: journalURL)
        var meeting = meeting
        let stoppedAt = lines.recordedUntil
        let resumedAt = now().timeIntervalSince(meeting.startedAt)
        meeting.gaps.append(Gap(span: TimeSpan(start: stoppedAt, end: max(stoppedAt, resumedAt)), reason: .crash))
        meeting.status = .recording
        meeting.endedAt = nil
        store.save(meeting)
        take(meeting, journal: journal, transcript: Transcript(lines: lines))
        phase = .recording
        let configuration = Configuration(
            title: meeting.title, audioSource: meeting.audioSource,
            locale: Locale(identifier: meeting.language), vocabulary: store.settings.vocabulary)
        startTask = Task { await start(configuration, resuming: true) }
    }

    /// Ends a meeting a crash or quit cut off, where its recording stopped.
    /// Task 17 routes it to the finisher.
    func finishInterrupted(_ meeting: Meeting) async {
        guard meeting.id != self.meeting?.id || phase == .idle else { return }
        var meeting = meeting
        let lines = (try? store.transcriptLines(for: meeting.id)) ?? []
        meeting.endedAt = meeting.startedAt.addingTimeInterval(lines.recordedUntil)
        meeting.status = .ready
        store.save(meeting)
    }

    /// Starts over with `meeting`, whose final lines go to `journal`.
    private func take(_ meeting: Meeting, journal: TranscriptJournal, transcript: Transcript) {
        self.meeting = meeting
        self.journal = journal
        self.transcript = transcript
        notices = []
        offsets = [:]
        meetingAudio = makeAudioBuffer()
        capturesMeeting = false
        heardMeeting = false
        startupStatus = "Menyiapkan pengenalan suara…"
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

    /// A resumed meeting keeps its start time; it is already recording.
    private func start(_ configuration: Configuration, resuming: Bool) async {
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
            failStart(message)
            return
        }
        guard !Task.isCancelled else { return }

        startupStatus = "Memulai rekaman…"
        let devices = makeDevices(configuration.audioSource)
        self.devices = devices
        let micAllowed = await type(of: devices.mic).requestPermission()
        guard !Task.isCancelled else { return }

        if !resuming {
            // Meeting time 0 is when capture starts, not when the start began.
            meeting?.startedAt = now()
            if let meeting { store.save(meeting) }
        }
        startCapture(devices, micAllowed: micAllowed, speech: speech)
        startupStatus = nil
        guard !listeners.isEmpty else {
            failStart(notices.map(\.message).joined(separator: "\n"))
            return
        }
        phase = .recording
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
        // A resumed meeting may still be getting capture ready.
        startTask?.cancel()
        startTask = nil
        startupStatus = nil
        monitorTask?.cancel()
        monitorTask = nil
        stopCapture()
        await finishListeners(within: .seconds(3))
        // The relays end with the capture streams; nothing may write to the
        // buffer once it's wiped.
        relays.forEach { $0.cancel() }
        for relay in relays { await relay.value }
        relays = []
        transcript.discardVolatile(.meeting)
        transcript.discardVolatile(.mic)
        meeting?.status = status
        // An interrupted meeting goes on later.
        if status != .interrupted { meeting?.endedAt = now() }
        if let meeting { store.save(meeting) }
        journal?.close()
        journal = nil
        // Task 17 hands the buffer to the finisher instead.
        meetingAudio.wipe()
        phase = .idle
        return meeting
    }

    /// Nothing could be recorded: the meeting is saved as failed, with why.
    private func failStart(_ message: String) {
        discardCapture()
        meeting?.status = .failed
        meeting?.failure = message
        meeting?.endedAt = now()
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
        meetingAudio.wipe()
    }

    private func stopCapture() {
        devices?.meeting.stop()
        devices?.mic.stop()
        devices = nil
    }

    // MARK: Pipeline

    /// Starts both channels. A channel that can't start is reported, and the
    /// other records on its own.
    private func startCapture(_ devices: CaptureDevices, micAllowed: Bool, speech: any SttProvider) {
        reportFailures(of: devices)
        do {
            let stream = try devices.meeting.start()
            let offset = meetingTime
            offsets[.meeting] = offset
            capturesMeeting = true
            meetingAudio.beginSegment(atMeetingTime: offset)
            listen(to: tee(stream, into: meetingAudio), channel: .meeting, with: speech)
        } catch {
            post(.error(error.localizedDescription))
        }
        guard micAllowed else {
            post(.error(MicCapture.Failure.permissionDenied.localizedDescription))
            return
        }
        do {
            let stream = try devices.mic.start()
            offsets[.mic] = meetingTime
            listen(to: relay(stream), channel: .mic, with: speech)
        } catch {
            post(.error(error.localizedDescription))
        }
    }

    /// A device that can't be restarted mid-meeting stops its channel only.
    private func reportFailures(of devices: CaptureDevices) {
        if let tap = devices.meeting as? ProcessTapCapture {
            tap.onReattachFailure = { [weak self] error in
                self?.post(.error("Audio meeting berhenti terekam: \(error.localizedDescription)"))
            }
        }
        if let mic = devices.mic as? MicCapture {
            mic.onRestartFailure = { [weak self] error in
                self?.post(.error("Mic berhenti merekam: \(error.localizedDescription)"))
            }
        }
    }

    // The recognizer reads nothing for a few seconds while its analyzer
    // starts, and a capture keeps only its newest 128 chunks (about 1.4 s of
    // tap audio). A chunk dropped then never reaches speech, so every later
    // line of that channel would come out early, and meeting lines would no
    // longer match `meetingAudio` for speaker separation. So the relays read
    // the captures at once and hold whatever speech hasn't read yet, without
    // a limit: about 384 KB per second of lag for 48 kHz stereo, and nothing
    // once speech has stopped reading (its stream is gone then).

    /// Passes the mic audio on to speech without dropping any.
    private func relay(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        relays.append(Task.detached {
            for await chunk in audio { continuation.yield(chunk) }
            continuation.finish()
        })
        return stream
    }

    /// Passes the meeting audio on to speech without dropping any, and keeps
    /// a 16 kHz mono copy in `buffer`, off the main actor. Notes, at most
    /// every 2 s, that the meeting isn't silent. Reports once if the copy
    /// fails or reaches the buffer's cap.
    private func tee(_ audio: AsyncStream<AudioChunk>, into buffer: MeetingAudioBuffer) -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        relays.append(Task.detached { [weak self] in
            var converter = AudioConverter(target: .mono16kInt16)
            var lastHeard = ContinuousClock.now - .seconds(10)
            var isFull = false
            var conversionFailed = false
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
                if chunk.buffer.peakLevel > AVAudioPCMBuffer.silenceThreshold,
                   ContinuousClock.now - lastHeard > .seconds(2) {
                    lastHeard = .now
                    Task { @MainActor [weak self] in self?.heardMeetingAudio() }
                }
            }
            continuation.finish()
        })
        return stream
    }

    private func listen(to audio: AsyncStream<AudioChunk>, channel: Channel, with speech: any SttProvider) {
        listeners.append(Task { [weak self] in
            do {
                for try await update in speech.transcribe(audio) {
                    self?.handle(update, from: channel)
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
    /// A mic line that repeats what the meeting just said is the speakers'
    /// echo and is dropped.
    private func handle(_ update: TranscriptUpdate, from channel: Channel) {
        let time = meetingTime
        let offset = offsets[channel] ?? 0
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
    }

    // MARK: Background work

    /// Every 10 s while recording: warns if the meeting is silent.
    private func startMonitoring() {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled, phase == .recording else { return }
                warnIfMeetingSilent()
            }
        }
    }

    /// Counts from when the meeting channel started, which is late in a
    /// resumed meeting.
    private func warnIfMeetingSilent() {
        guard capturesMeeting, !heardMeeting, meetingTime - (offsets[.meeting] ?? 0) > Self.silenceDelay
        else { return }
        post(.silent)
    }

    private func heardMeetingAudio() {
        heardMeeting = true
        notices.removeAll { $0 == .silent }
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
