import SwiftUI

/// Meetings, newest first. The one recording has a red dot; one whose
/// minutes are being written, a spinner.
struct MeetingSidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(MeetingSession.self) private var session
    @Environment(MeetingFinisher.self) private var finisher
    @Binding var selection: Meeting.ID?
    let onNewMeeting: () -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(store.meetings) { meeting in
                MeetingRow(
                    meeting: meeting, isRecording: isRecording(meeting),
                    isProcessing: finisher.running[meeting.id] != nil)
                    .tag(meeting.id)
            }
        }
        .overlay {
            if store.meetings.isEmpty {
                Text("Belum ada meeting")
                    .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onNewMeeting) {
                Label("Meeting Baru", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .help("Meeting Baru (⌘N)")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private func isRecording(_ meeting: Meeting) -> Bool {
        session.meeting?.id == meeting.id && (session.phase == .recording || session.phase == .stopping)
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let isRecording: Bool
    let isProcessing: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title.isEmpty ? "Tanpa judul" : meeting.title)
                    .foregroundStyle(meeting.title.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 7, height: 7)
                    .help("Sedang merekam")
            } else if isProcessing {
                ProgressView()
                    .controlSize(.mini)
                    .help("Membuat notulen…")
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let date = meeting.startedAt.formatted(
            .dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "id_ID")))
        return meeting.status == .failed ? "\(date) · Gagal" : date
    }
}
