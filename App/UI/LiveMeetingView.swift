import SwiftUI

/// The meeting being recorded: title, timer and Selesai in the toolbar, the
/// live transcript below.
struct LiveMeetingView: View {
    @Environment(MeetingSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            if let status = session.startupStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            ForEach(session.notices) { notice in
                Label(notice.message, systemImage: notice == .silent ? "speaker.slash" : "exclamationmark.triangle")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            TranscriptView(transcript: session.transcript)
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                switch session.phase {
                case .starting:
                    Button("Batal") { session.cancelStart() }
                        .help("Batalkan meeting ini")
                case .recording:
                    timer
                    Button("Selesai") {
                        Task { _ = await session.stop() }
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Hentikan rekaman")
                case .stopping:
                    timer
                    ProgressView().controlSize(.small)
                case .idle:
                    EmptyView()
                }
            }
        }
    }

    private var title: String {
        let title = session.meeting?.title ?? ""
        return title.isEmpty ? "Tanpa judul" : title
    }

    /// Red dot and recording time.
    private var timer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Text(MeetingTime.format(session.elapsed)).monospacedDigit()
            }
            .padding(.horizontal, 6)
        }
        .help("Lama rekaman")
    }
}
