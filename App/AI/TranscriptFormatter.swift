import Foundation

enum TranscriptFormatter {
    /// The transcript as the AI reads it: a short header, then one line per
    /// utterance with speaker tokens ("[05:12] [[s3]]: teks").
    static func aiTranscript(lines: [TranscriptLine], meeting: Meeting) -> String {
        let duration = meeting.endedAt.map { $0.timeIntervalSince(meeting.startedAt) }
            ?? meeting.recordedUntil(lines)
        var header = [
            "Bahasa meeting: \(meeting.language)",
            "Durasi: \(MeetingTime.format(duration))",
        ]
        if !meeting.gaps.isEmpty {
            let gaps = meeting.gaps.map { "\(span($0.span)) (\(reason($0.reason)))" }
            header.append("Jeda rekaman: " + gaps.joined(separator: ", "))
        }
        if !meeting.micOff.isEmpty {
            header.append("Mic pemilik mati: " + meeting.micOff.map(span).joined(separator: ", "))
        }
        // The journal can be slightly out of order.
        let body = lines.sorted { $0.start < $1.start }.map {
            "[\(MeetingTime.format($0.start))] [[\(meeting.speaker(of: $0).rawValue)]]: \($0.text)"
        }
        return (header + [""] + body).joined(separator: "\n")
    }

    /// "42:10–58:30".
    static func span(_ span: TimeSpan) -> String {
        "\(MeetingTime.format(span.start))–\(MeetingTime.format(span.end))"
    }

    /// Why the recording broke off: "Mac tidur", "app berhenti", "perangkat
    /// audio hilang".
    static func reason(_ reason: Gap.Reason) -> String {
        switch reason {
        case .sleep: "Mac tidur"
        case .crash: "app berhenti"
        case .deviceLost: "perangkat audio hilang"
        }
    }
}
