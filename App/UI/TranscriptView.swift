import SwiftUI

/// Transcript lines with who spoke ("Saya" or "Lainnya") and when, plus each
/// channel's in-progress words, faded, at the end. Opens at the latest line
/// and follows new ones unless the owner scrolled up; scrolling back to the
/// end follows again.
///
/// A finished meeting's transcript names speakers as the meeting does now,
/// opens at the top, and scrolls to the line in `focus` and highlights it.
struct TranscriptView: View {
    let transcript: Transcript
    /// Set for a meeting that has ended.
    var finished: Finished?
    @Environment(\.textScale) private var scale
    @ViewState private var followsEnd = true

    struct Finished {
        var meeting: Meeting
        /// The line a time in the minutes points at.
        var focus: TranscriptLine.ID?
    }

    private struct ScrollState: Equatable {
        var offset: CGFloat
        var isAtEnd: Bool
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if transcript.lines.isEmpty && transcript.volatileText.isEmpty {
                        Text(finished == nil
                            ? "Transkrip muncul di sini begitu ada yang bicara."
                            : "Tidak ada percakapan yang terekam.")
                            .font(.scaled(.body, scale))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(transcript.lines) { line in
                        let speaker = speaker(of: line)
                        row(speaker.name, isMe: speaker.isMe, time: line.start) {
                            Text(line.text)
                        }
                        .background {
                            if line.id == finished?.focus {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.tint.opacity(0.12))
                                    .padding(.horizontal, -8)
                                    .padding(.vertical, -5)
                            }
                        }
                        .id(line.id)
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
                // A finished meeting's fills the window: one reading column.
                .frame(maxWidth: finished == nil ? .infinity : LiveMeetingView.columnWidth + 40, alignment: .leading)
                .frame(maxWidth: .infinity)
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
            // Only where it starts: a fixed bottom anchor while the content
            // grows would move the lines the owner scrolled up to.
            .defaultScrollAnchor(finished == nil ? .bottom : .top, for: .initialOffset)
            .onAppear {
                if finished == nil { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
            .task(id: finished?.focus) {
                if let focus = finished?.focus { proxy.scrollTo(focus, anchor: .center) }
            }
            .onChange(of: transcript) {
                if finished == nil, followsEnd { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
        }
    }

    private static let end = "end"

    /// The meeting's name for who said it, else "Saya" or "Lainnya".
    private func speaker(of line: TranscriptLine) -> (name: String, isMe: Bool) {
        guard let meeting = finished?.meeting else { return (Self.label(line.speaker), line.speaker == .me) }
        let speaker = meeting.speaker(of: line)
        return (meeting.displayName(for: speaker), speaker == .me)
    }

    /// "Saya", "Pembicara 2", or "Lainnya" before speakers are told apart.
    nonisolated static func label(_ speaker: SpeakerID) -> String {
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
