import Foundation

/// When the owner had the mic off, in meeting time. The minutes use these
/// periods to tell a quiet owner from a muted one.
struct MicOffTracker: Equatable {
    /// Finished periods, oldest first.
    private(set) var spans: [TimeSpan]
    /// Start of the period still going on.
    private var offSince: TimeInterval?

    /// `spans`: periods saved earlier, as when a meeting resumes.
    init(spans: [TimeSpan] = []) {
        self.spans = spans
    }

    var isOff: Bool { offSince != nil }

    /// Finished periods, plus the one still going on as if it ended at `time`.
    func spans(through time: TimeInterval) -> [TimeSpan] {
        guard let offSince else { return spans }
        return spans + [TimeSpan(start: offSince, end: max(offSince, time))]
    }

    /// Already off: the period keeps its first start.
    mutating func turnOff(at time: TimeInterval) {
        guard offSince == nil else { return }
        offSince = time
    }

    mutating func turnOn(at time: TimeInterval) {
        guard let offSince else { return }
        spans.append(TimeSpan(start: offSince, end: max(offSince, time)))
        self.offSince = nil
    }

    /// Ends a period still going on, as when the recording stops.
    mutating func close(at time: TimeInterval) {
        turnOn(at: time)
    }
}
