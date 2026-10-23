import Foundation

/// A stretch of the meeting, in seconds since it started.
struct TimeSpan: Codable, Equatable, Hashable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
}

/// Who spoke. "me" is the mic, "others" is the meeting audio before
/// diarization, "s1", "s2", … are the remote speakers it finds.
struct SpeakerID: RawRepresentable, Codable, Hashable, Sendable {
    var rawValue: String

    init(_ rawValue: String) { self.rawValue = rawValue }

    /// Nil for an empty ID.
    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    static let me = SpeakerID("me")
    static let others = SpeakerID("others")

    static func remote(_ number: Int) -> SpeakerID { SpeakerID("s\(number)") }

    /// The N of "sN", or nil for "me" and "others".
    var remoteNumber: Int? {
        guard rawValue.first == "s" else { return nil }
        return Int(rawValue.dropFirst())
    }
}

/// Which capture a line came from.
enum Channel: String, Codable, Sendable {
    case mic, meeting
}

struct TranscriptLine: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var channel: Channel
    var speaker: SpeakerID
    var text: String
    /// Seconds since the meeting started.
    var start: TimeInterval
    var end: TimeInterval
}

/// Audio that wasn't captured, so the transcript has a hole there.
struct Gap: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable { case sleep, crash, deviceLost }
    var span: TimeSpan
    var reason: Reason
}

/// A speaker's display name; nil until the user renames them.
struct SpeakerInfo: Codable, Equatable, Sendable {
    var id: SpeakerID
    var name: String?
}

/// The user moved one line to another speaker.
struct SpeakerAssignment: Codable, Equatable, Sendable {
    var line: UUID
    var speaker: SpeakerID
}

/// The user merged one speaker into another.
struct SpeakerMerge: Codable, Equatable, Sendable {
    var from: SpeakerID
    var to: SpeakerID
}

enum MeetingStatus: String, Codable, Sendable {
    case recording, interrupted, processing, ready, failed
}

struct Meeting: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var status: MeetingStatus
    var language: String
    var audioSource: MeetingAudioSource
    var gaps: [Gap] = []
    /// Stretches where the mic was switched off.
    var micOff: [TimeSpan] = []
    var speakers: [SpeakerInfo] = []
    var speakerAssignments: [SpeakerAssignment] = []
    var merges: [SpeakerMerge] = []
    /// Action items ticked off, by item ID.
    var actionItemsDone: Set<String> = []
    var notionPageID: String?
    var failure: String?
}

extension Meeting {
    /// Fields missing from an older meeting.json keep their defaults.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        status = try container.decode(MeetingStatus.self, forKey: .status)
        language = try container.decode(String.self, forKey: .language)
        audioSource = try container.decode(MeetingAudioSource.self, forKey: .audioSource)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        gaps = try container.decodeIfPresent([Gap].self, forKey: .gaps) ?? []
        micOff = try container.decodeIfPresent([TimeSpan].self, forKey: .micOff) ?? []
        speakers = try container.decodeIfPresent([SpeakerInfo].self, forKey: .speakers) ?? []
        speakerAssignments = try container.decodeIfPresent([SpeakerAssignment].self, forKey: .speakerAssignments) ?? []
        merges = try container.decodeIfPresent([SpeakerMerge].self, forKey: .merges) ?? []
        actionItemsDone = try container.decodeIfPresent(Set<String>.self, forKey: .actionItemsDone) ?? []
        notionPageID = try container.decodeIfPresent(String.self, forKey: .notionPageID)
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
    }
}
