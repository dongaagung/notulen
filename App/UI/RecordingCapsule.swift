import SwiftUI

/// The toolbar's recording indicator: a red level meter for the meeting
/// audio and the recording time. The toolbar draws its glass capsule.
struct RecordingCapsule: View {
    @Environment(MeetingSession.self) private var session

    var body: some View {
        HStack(spacing: 8) {
            LevelWave()
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let time = MeetingTime.format(session.elapsed)
                Text(time)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .accessibilityLabel("Merekam, \(time)")
            }
        }
        .padding(.horizontal, 8)
        .help("Lama rekaman")
    }

    /// Relative heights of the meter's bars, so it reads as a wave.
    static let bars: [CGFloat] = [0.45, 0.85, 0.6, 1, 0.4]

    /// How full the meter is for a peak `level` (0 to 1): -50 dBFS and
    /// below is empty, 0 dBFS full, on a decibel scale like the ear's.
    static func fraction(level: Float) -> CGFloat {
        guard level > 0 else { return 0 }
        let decibels = 20 * log10(Double(level))
        return CGFloat(min(1, max(0, (decibels + 50) / 50)))
    }
}

/// Reads the level on its own, so only the bars redraw ten times a second.
private struct LevelWave: View {
    @Environment(MeetingSession.self) private var session
    private let height: CGFloat = 14
    private let minimum: CGFloat = 3

    var body: some View {
        let fraction = RecordingCapsule.fraction(level: session.level)
        HStack(spacing: 2) {
            ForEach(RecordingCapsule.bars.indices, id: \.self) { index in
                Capsule()
                    .fill(.red)
                    .frame(width: 2, height: max(minimum, height * fraction * RecordingCapsule.bars[index]))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.12), value: fraction)
        .accessibilityHidden(true)
    }
}
