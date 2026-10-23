import SwiftUI

/// The meeting's notices, stacked at the top of the live view. Each one can
/// be closed; a closed notice comes back only if the session drops it and
/// posts it again later.
struct NoticeBanner: View {
    let notices: [MeetingNotice]
    /// IDs of the notices the owner closed.
    @ViewState private var closed: Set<String> = []

    var body: some View {
        // Each row brings its own gap, so nothing is left when all are closed.
        VStack(spacing: 0) {
            ForEach(Self.visible(notices, closed: closed)) { notice in
                row(notice)
                    .padding(.top, 8)
            }
        }
        .onChange(of: notices) {
            closed = Self.stillClosed(closed, notices: notices)
        }
    }

    private func row(_ notice: MeetingNotice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: Self.symbol(for: notice))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(notice.message)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button {
                closed.insert(notice.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Tutup")
            .accessibilityLabel("Tutup pemberitahuan")
        }
        .font(.callout)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    /// `notices` without the ones the owner closed, in order.
    static func visible(_ notices: [MeetingNotice], closed: Set<String>) -> [MeetingNotice] {
        notices.filter { !closed.contains($0.id) }
    }

    /// Forgets closed notices the session dropped, so they show again if posted anew.
    static func stillClosed(_ closed: Set<String>, notices: [MeetingNotice]) -> Set<String> {
        closed.intersection(notices.map(\.id))
    }

    static func symbol(for notice: MeetingNotice) -> String {
        switch notice {
        case .silent: "speaker.slash"
        case .resumedAfterSleep: "moon.zzz"
        case .micChanged: "mic"
        case .speakerOutput: "speaker.wave.2"
        case .liveNotesDelayed: "wifi.slash"
        case .error: "exclamationmark.triangle"
        }
    }
}
