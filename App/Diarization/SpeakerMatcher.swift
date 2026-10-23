import Foundation

/// One speaker's turn found by diarization, in meeting time. `label` is the
/// diarizer's own name for the speaker ("S1", "S2", …).
struct DiarizedSegment: Equatable, Sendable {
    var label: String
    var start: TimeInterval
    var end: TimeInterval
}

/// Gives each meeting-channel line the speaker who talked during it, and
/// numbers the speakers by who spoke first.
enum SpeakerMatcher {
    /// A line no turn overlaps goes to the nearest turn this close.
    static let nearbyTolerance: TimeInterval = 1.0

    /// Each meeting line goes to the label with the most time overlap (the
    /// turns of a label add up); on a tie, the label whose overlapping turn
    /// started first. With no overlap, the nearest turn within
    /// `nearbyTolerance`; beyond that the line stays "others". Labels become
    /// s1, s2, … in the order their first line starts; `speakers` lists them
    /// so, unnamed.
    static func assign(
        lines: [TranscriptLine], segments: [DiarizedSegment]
    ) -> (assignments: [SpeakerAssignment], speakers: [SpeakerInfo]) {
        let turns = segments.sorted { $0.start < $1.start }
        // The journal can be slightly out of order; numbers follow meeting time.
        let ordered = lines.enumerated()
            .filter { $0.element.channel == .meeting }
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        var numbers: [String: SpeakerID] = [:]
        var speakers: [SpeakerInfo] = []
        var assignments: [SpeakerAssignment] = []
        for line in ordered {
            guard let label = label(for: line, among: turns) else { continue }
            let speaker: SpeakerID
            if let known = numbers[label] {
                speaker = known
            } else {
                speaker = .remote(speakers.count + 1)
                numbers[label] = speaker
                speakers.append(SpeakerInfo(id: speaker, name: nil))
            }
            assignments.append(SpeakerAssignment(line: line.id, speaker: speaker))
        }
        return (assignments, speakers)
    }

    /// Overlaps this much shorter count as equal.
    private static let tieMargin: TimeInterval = 1e-6

    /// `turns` are sorted by start.
    private static func label(for line: TranscriptLine, among turns: [DiarizedSegment]) -> String? {
        var overlap: [String: TimeInterval] = [:]
        // Labels in the order their first overlapping turn starts.
        var overlapping: [String] = []
        var nearest: (label: String, distance: TimeInterval)?
        for turn in turns {
            // Later turns start too late to overlap or be near.
            if turn.start > line.end + nearbyTolerance { break }
            let shared = min(line.end, turn.end) - max(line.start, turn.start)
            if shared > 0 {
                if overlap[turn.label] == nil { overlapping.append(turn.label) }
                overlap[turn.label, default: 0] += shared
            }
            let distance = max(turn.start - line.end, line.start - turn.end, 0)
            if distance <= nearbyTolerance, distance < nearest?.distance ?? .infinity {
                nearest = (turn.label, distance)
            }
        }
        var best: (label: String, overlap: TimeInterval)?
        for label in overlapping {
            let total = overlap[label, default: 0]
            if best.map({ total > $0.overlap + tieMargin }) ?? true { best = (label, total) }
        }
        return best?.label ?? nearest?.label
    }
}
