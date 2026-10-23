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
    /// Providers with a key in the Keychain, so views update when one is
    /// saved or removed without reading the Keychain on every redraw.
    private(set) var providersWithKeys: Set<AIProvider> = []

    private let files: JSONFileStore?
    /// Prepended to Keychain account names; tests use their own.
    private let keychainPrefix: String

    static let settingsFile = "settings.json"
    static let meetingsDirectory = "meetings"

    init(files: JSONFileStore? = try? .applicationSupport(), keychainPrefix: String = "") {
        self.files = files
        self.keychainPrefix = keychainPrefix
        providersWithKeys = Set(AIProvider.allCases.filter { $0.acceptsAPIKey && apiKey(for: $0) != nil })
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

    // MARK: AI provider

    func apiKey(for provider: AIProvider) -> String? {
        guard let key = Keychain.read(account: keychainPrefix + provider.keychainAccount), !key.isEmpty else {
            return nil
        }
        return key
    }

    /// An empty key removes it.
    func setAPIKey(_ key: String, for provider: AIProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = keychainPrefix + provider.keychainAccount
        do {
            if trimmed.isEmpty {
                try Keychain.delete(account: account)
                providersWithKeys.remove(provider)
            } else {
                try Keychain.save(trimmed, account: account)
                providersWithKeys.insert(provider)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// What's missing before the active provider can be used, or nil.
    var aiProblem: String? {
        let provider = settings.aiProvider
        if provider.requiresAPIKey && !providersWithKeys.contains(provider) {
            return "Isi kunci API \(provider.shortName) di Pengaturan."
        }
        guard provider != .anthropic else { return nil }
        let models = settings.models(for: provider)
        if URL(string: models.baseURL.trimmingCharacters(in: .whitespaces))?.host() == nil {
            return "Isi alamat server \(provider.shortName) di Pengaturan."
        }
        if models.fastModel.trimmingCharacters(in: .whitespaces).isEmpty
            || models.smartModel.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Pilih model \(provider.shortName) di Pengaturan."
        }
        return nil
    }

    var isAIReady: Bool { aiProblem == nil }

    /// A client for the active provider, or nil while `aiProblem` says why not.
    func aiClient() -> (any LLMClient)? {
        guard isAIReady else { return nil }
        let provider = settings.aiProvider
        let key = provider.acceptsAPIKey ? apiKey(for: provider) : nil
        if provider == .anthropic {
            return key.map { ClaudeClient(apiKey: $0) }
        }
        let models = settings.models(for: provider)
        guard let baseURL = URL(string: models.baseURL.trimmingCharacters(in: .whitespaces)) else { return nil }
        return OpenAICompatibleClient(
            providerName: provider.shortName,
            baseURL: baseURL,
            apiKey: key,
            fastModel: models.fastModel.trimmingCharacters(in: .whitespaces),
            smartModel: models.smartModel.trimmingCharacters(in: .whitespaces),
            usesMaxCompletionTokens: provider.usesMaxCompletionTokens)
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

extension Meeting {
    /// Meeting time a recording that stopped unexpectedly is known to have
    /// reached: the end of its last line (`lines` is its journal), or of its
    /// last gap, since recording ran on after that. 0 when it has neither.
    func recordedUntil(_ lines: [TranscriptLine]) -> TimeInterval {
        max(lines.map(\.end).max() ?? 0, gaps.map(\.span.end).max() ?? 0)
    }
}
