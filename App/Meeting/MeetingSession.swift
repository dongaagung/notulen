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

    /// Meeting audio still silent this long after the start raises `.silent`.
    static let silenceDelay: TimeInterval = 20

    private let store: AppStore
    private let makeDevices: @MainActor (MeetingAudioSource) -> CaptureDevices
    private let makeSpeech: @Sendable (Locale, [String]) -> any SttProvider
    private let now: () -> Date

    private var devices: CaptureDevices?
    private var journal: TranscriptJournal?
    /// The meeting channel as 16 kHz mono, for speaker separation.
    private var meetingAudio = MeetingAudioBuffer()
    /// Meeting time at which each channel's current audio stream started.
    /// Recognizer spans count from there.
    private var offsets: [Channel: TimeInterval] = [:]
    private var startTask: Task<Void, Never>?
    private var listeners: [Task<Void, Never>] = []
    /// Copies the meeting audio into `meetingAudio`: its only writer.
    private var teeTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var capturesMeeting = false
    private var heardMeeting = false

    init(
        store: AppStore,
        devices: @escaping @MainActor (MeetingAudioSource) -> CaptureDevices = CaptureDevices.live,
        speech: @escaping @Sendable (Locale, [String]) -> any SttProvider = {
            SpeechAnalyzerProvider(locale: $0, vocabulary: $1)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.makeDevices = devices
        self.makeSpeech = speech
        self.now = now
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
        do {
            journal = try TranscriptJournal(url: journalURL)
        } catch {
            store.delete(meeting)
            throw error
        }
        self.meeting = meeting
        transcript = Transcript()
        notices = []
        offsets = [:]
        meetingAudio = MeetingAudioBuffer()
        capturesMeeting = false
        heardMeeting = false
        startupStatus = "Menyiapkan pengenalan suara…"
        phase = .starting
        startTask = Task { await start(configuration) }
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

    private func start(_ configuration: Configuration) async {
        let speech = makeSpeech(configuration.locale, configuration.vocabulary)
        do {
            // Downloads the on-device speech model on first use.
            try await speech.prepare { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, phase == .starting else { return }
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

        // Meeting time 0 is when capture starts, not when the start began.
        meeting?.startedAt = now()
        if let meeting { store.save(meeting) }
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
        guard phase == .recording else { return nil }
        phase = .stopping
        monitorTask?.cancel()
        monitorTask = nil
        stopCapture()
        await finishListeners(within: .seconds(3))
        // The tee ends with the capture stream; nothing may write to the
        // buffer once it's wiped.
        teeTask?.cancel()
        await teeTask?.value
        teeTask = nil
        transcript.discardVolatile(.meeting)
        transcript.discardVolatile(.mic)
        meeting?.endedAt = now()
        meeting?.status = .ready
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

    /// Lets go of what a start set up. The tee only runs once recording, so
    /// the buffer can be wiped here.
    private func discardCapture() {
        assert(teeTask == nil)
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
            listen(to: stream, channel: .mic, with: speech)
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

    /// Passes the meeting audio on to speech and keeps a 16 kHz mono copy in
    /// `buffer`, off the main actor. Notes, at most every 2 s, that the
    /// meeting isn't silent.
    private func tee(_ audio: AsyncStream<AudioChunk>, into buffer: MeetingAudioBuffer) -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .bufferingNewest(128))
        teeTask = Task.detached { [weak self] in
            var converter = AudioConverter(target: .mono16kInt16)
            var lastHeard = ContinuousClock.now - .seconds(10)
            for await chunk in audio {
                continuation.yield(chunk)
                if let mono = try? converter.convert(chunk.buffer) {
                    buffer.append(mono)
                }
                if chunk.buffer.peakLevel > AVAudioPCMBuffer.silenceThreshold,
                   ContinuousClock.now - lastHeard > .seconds(2) {
                    lastHeard = .now
                    Task { @MainActor [weak self] in self?.heardMeetingAudio() }
                }
            }
            continuation.finish()
        }
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

    private func warnIfMeetingSilent() {
        guard capturesMeeting, !heardMeeting, meetingTime > Self.silenceDelay else { return }
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
