import SwiftUI

/// The meeting being recorded: title, timer, the mic button and Selesai in
/// the toolbar, the live transcript below. Asks what to do after a long
/// sleep, and offers to finish once the meeting looks over.
struct LiveMeetingView: View {
    @Environment(MeetingSession.self) private var session

    static let finishOffer = "Meeting sepertinya sudah selesai. Selesaikan rekaman?"

    /// ⇧⌘M is the app menu's Matikan Mic / Nyalakan Mic.
    static func micToggleHelp(micOn: Bool) -> String {
        micOn ? "Matikan mic (⇧⌘M)" : "Nyalakan mic (⇧⌘M)"
    }

    /// Asked when the Mac woke after sleeping longer than `WakePolicy.resumeLimit`.
    static func wakeQuestion(sleptFor duration: TimeInterval, title: String) -> String {
        "Mac tidur selama \(MeetingTime.duration(duration)). Lanjutkan merekam “\(title)” atau Selesaikan?"
    }

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
                Label(notice.message, systemImage: Self.symbol(for: notice))
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
            TranscriptView(transcript: session.transcript)
                // Not on the same view as the wake question: one view, one alert.
                .alert(Self.finishOffer, isPresented: offersFinish) {
                    // Task.immediate: the offer is gone before the alert closes.
                    Button("Selesai") { Task.immediate { _ = await session.stop() } }
                    Button("Tetap merekam", role: .cancel) { session.declineFinishOffer() }
                }
        }
        .alert(Self.wakeQuestion(sleptFor: session.wakeQuestion ?? 0, title: title), isPresented: asksAfterWake) {
            // No cancel: nothing records until the owner picks one.
            Button("Lanjutkan") { Task.immediate { await session.answerWake(continueRecording: true) } }
                .keyboardShortcut(.defaultAction)
            Button("Selesaikan") { Task.immediate { await session.answerWake(continueRecording: false) } }
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
                    micToggle
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

    /// The buttons answer; the session then clears the question.
    private var asksAfterWake: Binding<Bool> {
        Binding { session.wakeQuestion != nil } set: { _ in }
    }

    /// The buttons answer; the session then clears the offer.
    private var offersFinish: Binding<Bool> {
        Binding { session.offersFinish } set: { _ in }
    }

    private static func symbol(for notice: MeetingNotice) -> String {
        switch notice {
        case .silent: "speaker.slash"
        case .resumedAfterSleep: "moon.zzz"
        case .micChanged: "mic"
        case .speakerOutput: "speaker.wave.2"
        case .error: "exclamationmark.triangle"
        }
    }

    /// Off keeps the owner's side talk out of the transcript; the meeting
    /// audio records on.
    private var micToggle: some View {
        Button {
            session.setMicEnabled(!session.isMicOn)
        } label: {
            Label(
                session.isMicOn ? "Matikan Mic" : "Nyalakan Mic",
                systemImage: session.isMicOn ? "mic" : "mic.slash")
        }
        .help(Self.micToggleHelp(micOn: session.isMicOn))
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
