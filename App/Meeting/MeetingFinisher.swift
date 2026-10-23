import Foundation
import Observation

/// Turns an ended meeting into its minutes: the meeting is processing
/// meanwhile, then ready (with minutes, or without when nothing was said) or
/// failed with why, to try again. The transcript is never changed.
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

    /// The steps a finish goes through, in order. Speaker separation joins
    /// in a later task.
    static let steps: [Step] = [.writingMinutes]

    /// What each meeting being finished is doing now, by meeting ID.
    private(set) var running: [UUID: Step] = [:]

    private let store: AppStore
    private let writer: @MainActor () -> MinutesWriter?

    /// `writer` is nil while the AI provider isn't ready.
    init(store: AppStore, writer: @escaping @MainActor () -> MinutesWriter?) {
        self.store = store
        self.writer = writer
    }

    /// Writes with the active provider's smart model and prompts/minutes.md.
    convenience init(store: AppStore) {
        self.init(store: store) {
            guard let client = store.aiClient(), let template = try? PromptTemplate.load("minutes") else {
                return nil
            }
            return MinutesWriter(client: client, template: template)
        }
    }

    /// Writes the minutes of a meeting that just ended. `audio` is its
    /// meeting audio, if it still has any; it's wiped whatever happens.
    func finish(_ id: UUID, audio: MeetingAudioBuffer?) async {
        // Speaker separation reads the audio first, in a later task; nothing
        // needs it after that.
        audio?.wipe()
        await writeMinutes(id)
    }

    /// Writes the minutes again, as after merging speakers or a failure.
    /// Ticked action items and translations go: the new items have new IDs.
    func regenerate(_ id: UUID) async {
        guard running[id] == nil, var meeting = store.meeting(id) else { return }
        meeting.actionItemsDone = []
        meeting.translations = [:]
        store.save(meeting)
        await writeMinutes(id)
    }

    /// Ready with minutes; ready without when nothing was said (no AI
    /// needed); failed with why otherwise. Changes the owner makes
    /// meanwhile, such as the title or speaker names, are kept.
    private func writeMinutes(_ id: UUID) async {
        guard running[id] == nil, var meeting = store.meeting(id) else { return }
        running[id] = .writingMinutes
        defer { running[id] = nil }
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
