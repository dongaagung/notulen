import Foundation

enum MeetingTime {
    /// "05:12" under an hour, "1:15:14" from one hour on.
    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.isFinite ? max(0, seconds) : 0)
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// A length in words, to the nearest minute: "12 menit", "1 jam 20
    /// menit", "2 jam". Under a minute, in seconds: "45 detik".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int((seconds.isFinite ? max(0, seconds) : 0).rounded())
        if total < 60 { return "\(total) detik" }
        let minutes = Int((Double(total) / 60).rounded())
        let (hours, rest) = (minutes / 60, minutes % 60)
        if hours == 0 { return "\(minutes) menit" }
        return rest == 0 ? "\(hours) jam" : "\(hours) jam \(rest) menit"
    }
}
