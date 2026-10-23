import Foundation

/// Tells when a meeting looks over, so the owner can be offered to finish
/// it: its audio has been quiet for `silenceLimit`, or the meeting app
/// quit. Times are meeting time. It never ends a recording itself.
struct MeetingEndDetector {
    static let silenceLimit: TimeInterval = 10 * 60

    /// Where the current quiet stretch began.
    private var quietSince: TimeInterval
    /// The current quiet stretch was offered already.
    private var offeredQuiet = false
    /// The app's quit was offered already. Cleared once the app runs again.
    private var offeredQuit = false

    init(startedAt: TimeInterval) {
        quietSince = startedAt
    }

    /// The meeting audio was above the silence threshold at `time`.
    mutating func heardSound(at time: TimeInterval) {
        quietSince = max(quietSince, time)
        offeredQuiet = false
    }

    /// True once per quiet stretch of `silenceLimit`, or once when the
    /// meeting app quits. Either way the quiet stretch counts as offered.
    mutating func shouldOffer(at now: TimeInterval, appRunning: Bool) -> Bool {
        if appRunning {
            offeredQuit = false
        } else if !offeredQuit {
            offeredQuit = true
            offeredQuiet = true
            return true
        }
        guard !offeredQuiet, now - quietSince >= Self.silenceLimit else { return false }
        offeredQuiet = true
        return true
    }

    /// The owner chose to keep recording: the next offer comes after another
    /// `silenceLimit` of quiet from `now`.
    mutating func declined(at now: TimeInterval) {
        quietSince = max(quietSince, now)
        offeredQuiet = false
    }
}
