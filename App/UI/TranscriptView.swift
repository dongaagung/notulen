import SwiftUI

/// Transcript lines with who spoke ("Saya" or "Lainnya") and when, plus each
/// channel's in-progress words, faded, at the end. Follows new lines unless
/// the owner scrolled up; scrolling back to the end follows again.
struct TranscriptView: View {
    let transcript: Transcript
    @Environment(\.textScale) private var scale
    @ViewState private var followsEnd = true

    private struct ScrollState: Equatable {
        var offset: CGFloat
        var isAtEnd: Bool
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if transcript.lines.isEmpty && transcript.volatileText.isEmpty {
                        Text("Transkrip muncul di sini begitu ada yang bicara.")
                            .font(.scaled(.body, scale))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(transcript.lines) { line in
                        row(Self.label(line.speaker), isMe: line.speaker == .me, time: line.start) {
                            Text(line.text)
                        }
                    }
                    ForEach([Channel.meeting, .mic], id: \.self) { channel in
                        if let text = transcript.volatileText[channel] {
                            row(channel == .mic ? "Saya" : "Lainnya", isMe: channel == .mic, time: nil) {
                                Text(text).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.end)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollGeometryChange(for: ScrollState.self) { geometry in
                ScrollState(
                    offset: geometry.contentOffset.y,
                    isAtEnd: geometry.visibleRect.maxY >= geometry.contentSize.height - 24)
            } action: { old, new in
                // New lines grow the content without moving the offset; only
                // the owner scrolls it up.
                if new.isAtEnd {
                    followsEnd = true
                } else if new.offset < old.offset - 1 {
                    followsEnd = false
                }
            }
            .onChange(of: transcript) {
                if followsEnd { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
        }
    }

    private static let end = "end"

    private static func label(_ speaker: SpeakerID) -> String {
        if speaker == .me { return "Saya" }
        if let number = speaker.remoteNumber { return "Pembicara \(number)" }
        return "Lainnya"
    }

    private func row(
        _ label: String, isMe: Bool, time: TimeInterval?, @ViewBuilder text: () -> Text
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.scaled(.caption, scale, weight: .semibold))
                    .foregroundStyle(isMe ? Color.accentColor : .secondary)
                if let time {
                    Text(MeetingTime.format(time))
                        .font(.scaled(.caption, scale).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            text()
                .font(.scaled(.body, scale))
                .textSelection(.enabled)
        }
    }
}
