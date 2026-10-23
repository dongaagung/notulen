import FluidAudio
import Foundation

/// Tells the remote speakers apart in a meeting's audio.
protocol SpeakerDiarizing: Sendable {
    /// The speakers' turns in meeting time; empty when nobody spoke.
    func diarize(_ audio: MeetingAudioBuffer) async throws -> [DiarizedSegment]
}

/// FluidAudio reads the meeting audio straight from RAM.
extension MeetingAudioBuffer: AudioSampleSource {}

/// FluidAudio's offline pipeline over the bundled models, loaded on first
/// use and kept. The audio is read in place: nothing goes to disk, and no
/// voice embedding outlives the call. One meeting at a time: FluidAudio
/// blocks Swift concurrency threads in Core ML, and several runs at once
/// can take them all and never finish.
actor SpeakerDiarizer: SpeakerDiarizing {
    private let modelsDirectory: URL
    private var models: OfflineDiarizerModels?
    private var isBusy = false
    /// Calls waiting for the one running now, oldest first.
    private var queue: [CheckedContinuation<Void, Never>] = []

    /// `modelsDirectory` holds `speaker-diarization/`.
    init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    /// One over the bundled models; nil when the app has none.
    static func bundled() -> SpeakerDiarizer? {
        DiarizationModels.directory().map { SpeakerDiarizer(modelsDirectory: $0) }
    }

    func diarize(_ audio: MeetingAudioBuffer) async throws -> [DiarizedSegment] {
        await takeTurn()
        defer { endTurn() }
        let models = try await loadedModels()
        // A manager per call: it isn't Sendable, and holds nothing worth keeping.
        let manager = OfflineDiarizerManager(config: .default)
        manager.initialize(models: models)
        let result: DiarizationResult
        do {
            result = try await manager.process(audioSource: audio, audioLoadingSeconds: 0)
        } catch OfflineDiarizationError.noSpeechDetected {
            return []
        }
        return Self.meetingSegments(result.segments, in: audio)
    }

    /// FluidAudio's turns, timed in the stored audio, in meeting time. A turn
    /// across a gap in the recording (sleep, resume) is split there.
    static func meetingSegments(_ turns: [TimedSpeakerSegment], in audio: MeetingAudioBuffer) -> [DiarizedSegment] {
        turns.flatMap { turn in
            audio.meetingSpans(fromBufferTime: Double(turn.startTimeSeconds), to: Double(turn.endTimeSeconds))
                .map { DiarizedSegment(label: turn.speakerId, start: $0.start, end: $0.end) }
        }
    }

    private func takeTurn() async {
        guard isBusy else {
            isBusy = true
            return
        }
        // `endTurn` hands the turn straight over.
        await withCheckedContinuation { queue.append($0) }
    }

    private func endTurn() {
        if queue.isEmpty {
            isBusy = false
        } else {
            queue.removeFirst().resume()
        }
    }

    private func loadedModels() async throws -> OfflineDiarizerModels {
        if let models { return models }
        let loaded = try await OfflineDiarizerModels.load(from: modelsDirectory)
        models = loaded
        return loaded
    }
}
