import Foundation
import Observation

/// App-wide state persisted as JSON in Application Support. API keys are
/// the exception: they only ever go to the Keychain.
@MainActor
@Observable
final class AppStore {
    var settings = AppSettings() {
        didSet { persist(settings, to: Self.settingsFile) }
    }
    /// Newest first.
    private(set) var meetings: [Meeting] = []
    /// Last persistence error, shown in the UI.
    var lastError: String?

    private let files: JSONFileStore?
    /// Prepended to Keychain account names; tests use their own.
    private let keychainPrefix: String

    static let settingsFile = "settings.json"
    static let meetingsDirectory = "meetings"

    init(files: JSONFileStore? = try? .applicationSupport(), keychainPrefix: String = "") {
        self.files = files
        self.keychainPrefix = keychainPrefix
        guard let files else {
            lastError = "Tidak bisa membuka Application Support; perubahan tidak akan tersimpan."
            return
        }
        do {
            settings = try files.load(AppSettings.self, from: Self.settingsFile) ?? AppSettings()
        } catch {
            lastError = "Pengaturan tidak bisa dibaca; memakai pengaturan awal."
        }
        // One unreadable meeting must not hide the others.
        meetings = files.subdirectories(Self.meetingsDirectory).compactMap { name in
            do {
                return try files.load(Meeting.self, from: "\(Self.meetingsDirectory)/\(name)/\(Self.meetingFile)")
            } catch {
                lastError = "Meeting di folder \(name) tidak bisa dibaca."
                return nil
            }
        }.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: Meetings

    func save(_ meeting: Meeting) {
        persist(meeting, to: Self.meetingPath(meeting.id))
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.append(meeting)
        }
        meetings.sort { $0.startedAt > $1.startedAt }
    }

    /// Removes the meeting's whole folder, transcript included.
    func delete(_ meeting: Meeting) {
        do {
            try files?.remove(Self.meetingFolder(meeting.id))
            meetings.removeAll { $0.id == meeting.id }
        } catch {
            lastError = "Meeting tidak bisa dihapus: \(error.localizedDescription)"
        }
    }

    /// Where the meeting's transcript journal lives; nil without storage.
    func transcriptURL(for id: UUID) -> URL? {
        files?.directory.appending(path: "\(Self.meetingFolder(id))/\(Self.transcriptFile)")
    }

    /// The meeting's journaled lines; empty before the first one.
    func transcriptLines(for id: UUID) throws -> [TranscriptLine] {
        guard let url = transcriptURL(for: id), FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try TranscriptJournal.read(url)
    }

    // MARK: Recovery

    /// Meetings a crash or force quit left recording become interrupted
    /// (saved). Returns every interrupted meeting, newest first, for the
    /// owner to resume or finish; quitting while recording leaves one too.
    /// Call at launch only: later, a recording meeting is the one recording now.
    func recoverInterrupted() -> [Meeting] {
        for var meeting in meetings where meeting.status == .recording {
            meeting.status = .interrupted
            save(meeting)
        }
        return meetings.filter { $0.status == .interrupted }
    }

    private static let meetingFile = "meeting.json"
    private static let transcriptFile = "transcript.jsonl"

    private static func meetingFolder(_ id: UUID) -> String {
        "\(meetingsDirectory)/\(id.uuidString)"
    }

    private static func meetingPath(_ id: UUID) -> String {
        "\(meetingFolder(id))/\(meetingFile)"
    }

    // MARK: Persistence

    private func persist<T: Encodable>(_ value: T, to path: String) {
        do {
            try files?.save(value, to: path)
        } catch {
            lastError = "Tidak bisa menyimpan \(path): \(error.localizedDescription)"
        }
    }
}

extension [TranscriptLine] {
    /// Meeting time where these lines end: where a recording that stopped
    /// unexpectedly last heard anything. 0 without lines.
    var recordedUntil: TimeInterval { map(\.end).max() ?? 0 }
}
