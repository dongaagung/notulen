import SwiftUI

/// Meetings by date, newest first, with search. The one recording has a red dot; one whose
/// minutes are being written, a spinner.
struct MeetingSidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(MeetingSession.self) private var session
    @Environment(MeetingFinisher.self) private var finisher
    @Binding var selection: Meeting.ID?
    let onNewMeeting: () -> Void
    @ViewState private var query = ""
    @ViewState private var pendingDelete: Meeting?

    var body: some View {
        let groups = MeetingGroups.group(
            store.meetings.filter { MeetingGroups.matches($0, query: query) }, now: .now, calendar: MeetingGroups.calendar)
        List(selection: $selection) {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.meetings) { meeting in
                        MeetingRow(
                            meeting: meeting, isRecording: isRecording(meeting),
                            isProcessing: finisher.running[meeting.id] != nil)
                            .tag(meeting.id)
                            .contextMenu {
                                Button("Hapus…") { pendingDelete = meeting }
                                    .disabled(isActive(meeting))
                            }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Cari meeting")
        .overlay {
            if store.meetings.isEmpty {
                Text("Belum ada meeting")
                    .foregroundStyle(.secondary)
            } else if groups.isEmpty {
                Text("Tidak ada yang cocok")
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "Hapus “\(pendingDelete.map(displayTitle) ?? "")”? Transkrip dan notulennya ikut terhapus.",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible, presenting: pendingDelete
        ) { meeting in
            Button("Hapus", role: .destructive) {
                if selection == meeting.id { selection = nil }
                store.delete(meeting)
            }
            Button("Batal", role: .cancel) {}
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

    private func displayTitle(_ meeting: Meeting) -> String {
        meeting.title.isEmpty ? "Tanpa judul" : meeting.title
    }

    /// Not deletable: it is recording, or being resumed or finished.
    private func isActive(_ meeting: Meeting) -> Bool {
        session.meeting?.id == meeting.id && session.phase != .idle
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
