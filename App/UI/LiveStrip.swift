import SwiftUI

/// The glass strip at the bottom of the live view: the last thing said and
/// who said it, with the words still being recognized faded. While the mic
/// is off it says so instead.
struct LiveStrip: View {
    @Environment(MeetingSession.self) private var session
    @Environment(\.textScale) private var scale

    var body: some View {
        content
            .font(.scaled(.body, scale))
            .lineLimit(2)
            // The newest words matter most.
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        if !session.isMicOn {
            Label("Mic mati", systemImage: "mic.slash")
                .foregroundStyle(.secondary)
        } else if let caption = Caption.latest(in: session.transcript) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(caption.speaker)
                    .font(.scaled(.caption, scale, weight: .semibold))
                    .foregroundStyle(caption.isMe ? Color.accentColor : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                caption.text
            }
        } else {
            Text("Menunggu percakapan…")
                .foregroundStyle(.tertiary)
        }
    }

    /// The latest speech: one speaker's last final line, then the words of
    /// theirs still being recognized.
    struct Caption: Equatable {
        var speaker: String
        var isMe: Bool
        /// The transcript's last line, when it is this speaker's.
        var final: String?
        /// Still changing.
        var pending: String?

        /// Whoever is speaking now, the meeting before the mic; when nobody
        /// is, whoever spoke last. Named the way the transcript names them.
        /// Nil before anyone spoke.
        static func latest(in transcript: Transcript) -> Caption? {
            let channel: Channel
            if transcript.volatileText[.meeting] != nil {
                channel = .meeting
            } else if transcript.volatileText[.mic] != nil {
                channel = .mic
            } else if let last = transcript.lines.last {
                channel = last.channel
            } else {
                return nil
            }
            let final = transcript.lines.last.flatMap { $0.channel == channel ? $0 : nil }
            let speaker = final?.speaker ?? (channel == .mic ? .me : .others)
            return Caption(
                speaker: TranscriptView.label(speaker), isMe: speaker == .me,
                final: final?.text, pending: transcript.volatileText[channel])
        }

        var text: Text {
            switch (final, pending) {
            case let (final?, pending?): Text("\(Text(final)) \(Text(pending).foregroundStyle(.secondary))")
            case let (final?, nil): Text(final)
            case let (nil, pending?): Text(pending).foregroundStyle(.secondary)
            case (nil, nil): Text("")
            }
        }
    }
}
