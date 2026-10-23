import Foundation
import Observation

/// Turns an ended meeting into its minutes: first the remote speakers are
/// told apart in its audio, then the minutes are written. The meeting is
/// processing meanwhile, then ready (with minutes, or without when nothing
/// was said) or failed with why, to try again. The transcript is never
/// changed: the speakers go to the meeting as line assignments.
@MainActor
@Observable
final class MeetingFinisher {
    enum Step: Equatable {
        case separatingSpeakers, writingMinutes

        var label: String {
            switch self {
            case .separatingSpeakers: "Memisahkan pembicara…"
            case .writingMinutes: "Menulis notulen…"
            }
        }
    }

    /// Every step a finish can go through, in order.
    static let steps: [Step] = [.separatingSpeakers, .writingMinutes]

    /// What each meeting being finished is doing now, by meeting ID.
    private(set) var running: [UUID: Step] = [:]
    /// Meetings whose finish separates speakers; other runs only write.
    private var separating: Set<UUID> = []

    private let store: AppStore
    private let diarizer: (any SpeakerDiarizing)?
    private let writer: @MainActor () -> MinutesWriter?

    /// `diarizer` is nil without diarization models: the meeting's lines
    /// then stay "Lainnya". `writer` is nil while the AI provider isn't
    /// ready.
    init(store: AppStore, diarizer: (any SpeakerDiarizing)?, writer: @escaping @MainActor () -> MinutesWriter?) {
        self.store = store
        self.diarizer = diarizer
        self.writer = writer
    }

    /// Separates speakers with the bundled models, if the app has them, and
    /// writes with the active provider's smart model and prompts/minutes.md.
    convenience init(store: AppStore, diarizer: (any SpeakerDiarizing)? = SpeakerDiarizer.bundled()) {
        self.init(store: store, diarizer: diarizer) {
            guard let client = store.aiClient(), let template = try? PromptTemplate.load("minutes") else {
                return nil
            }
            return MinutesWriter(client: client, template: template)
        }
    }

    /// The steps the meeting's finish goes through, for showing progress.
    func steps(for id: UUID) -> [Step] {
        separating.contains(id) ? Self.steps : [.writingMinutes]
    }

    /// Tells the speakers apart in the meeting audio, if there is any and
    /// the models are there, then writes the minutes. `audio` is the
    /// meeting's audio, if it still has any; it's wiped once the speakers
    /// are separated, before the minutes, whatever happens.
    func finish(_ id: UUID, audio: MeetingAudioBuffer?) async {
        defer { audio?.wipe() }
        guard running[id] == nil, store.meeting(id) != nil else { return }
        defer {
            running[id] = nil
            separating.remove(id)
        }
        if let audio, audio.sampleCount > 0, let diarizer {
            separating.insert(id)
            running[id] = .separatingSpeakers
            await separateSpeakers(id, audio: audio, with: diarizer)
        }
        // Nothing needs the audio now; the minutes take a while.
        audio?.wipe()
        await writeMinutes(id)
    }

    /// Writes the minutes again, as after merging speakers or a failure.
    /// Ticked action items and translations go: the new items usually reuse
    /// IDs like a1, a2, so old ticks would land on different tasks.
    /// The speakers stay as they are: the audio is long gone.
    func regenerate(_ id: UUID) async {
        guard running[id] == nil, var meeting = store.meeting(id) else { return }
        defer { running[id] = nil }
        meeting.actionItemsDone = []
        meeting.translations = [:]
        store.save(meeting)
        await writeMinutes(id)
    }

    /// Gives the meeting's lines the speakers heard in its audio. When that
    /// fails, or nobody spoke, the lines stay "Lainnya" and the minutes are
    /// written anyway. Changes the owner makes meanwhile are kept.
    private func separateSpeakers(_ id: UUID, audio: MeetingAudioBuffer, with diarizer: any SpeakerDiarizing) async {
        guard let segments = try? await diarizer.diarize(audio),
              let lines = try? store.transcriptLines(for: id)
        else { return }
        let matched = SpeakerMatcher.assign(lines: lines, segments: segments)
        guard var meeting = store.meeting(id) else { return }
        meeting.speakers = matched.speakers
        meeting.speakerAssignments = matched.assignments
        store.save(meeting)
    }

    /// Ready with minutes; ready without when nothing was said (no AI
    /// needed); failed with why otherwise. Changes the owner makes
    /// meanwhile, such as the title or speaker names, are kept. The caller
    /// guards against a second run and clears `running` after.
    private func writeMinutes(_ id: UUID) async {
        guard var meeting = store.meeting(id) else { return }
        running[id] = .writingMinutes
        meeting.status = .processing
        meeting.failure = nil
        store.save(meeting)

        let lines: [TranscriptLine]
        do {
            lines = try store.transcriptLines(for: id)
        } catch {
            end(id) { $0.fail("Transkrip tidak bisa dibaca: \(error.localizedDescription)") }
            return
        }
        guard MinutesWriter.hasSpeech(lines) else {
            end(id) { $0.finish(with: nil) }
            return
        }
        guard let writer = writer() else {
            let problem = store.aiProblem ?? "AI belum bisa dipakai. Periksa Pengaturan."
            end(id) { $0.fail(problem) }
            return
        }
        do {
            let minutes = try await writer.write(meeting: meeting, lines: lines)
            end(id) { $0.finish(with: minutes) }
        } catch MinutesWriter.Failure.nothingRecorded {
            end(id) { $0.finish(with: nil) }
        } catch {
            end(id) { $0.fail(error.localizedDescription) }
        }
    }

    /// Applies the outcome to the meeting as it is now, unless it was deleted.
    private func end(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard var meeting = store.meeting(id) else { return }
        change(&meeting)
        store.save(meeting)
    }
}

private extension Meeting {
    /// An untitled meeting takes the title the AI suggests.
    mutating func finish(with minutes: Minutes?) {
        self.minutes = minutes
        status = .ready
        failure = nil
        let suggestion = minutes?.titleSuggestion.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !suggestion.isEmpty {
            title = suggestion
        }
    }

    mutating func fail(_ reason: String) {
        status = .failed
        failure = reason
    }
}
