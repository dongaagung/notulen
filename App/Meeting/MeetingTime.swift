import Foundation

enum MeetingTime {
    /// "05:12" under an hour, "1:15:14" from one hour on.
    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
