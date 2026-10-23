import SwiftUI

struct ContentView: View {
    /// Set by the sidebar button and ⌘N.
    @Binding var showsNewMeeting: Bool
    @Environment(AppStore.self) private var store
    @Environment(MeetingSession.self) private var session
    @Environment(MeetingFinisher.self) private var finisher
    @ViewState private var selection: Meeting.ID?
    /// Meetings a crash or quit cut off, asked about one at a time.
    @ViewState private var interrupted: [Interrupted] = []

    private struct Interrupted {
        var meeting: Meeting
        /// Where its recording stopped, in meeting time.
        var stoppedAt: TimeInterval
    }

    var body: some View {
        NavigationSplitView {
            MeetingSidebar(selection: $selection) { showsNewMeeting = true }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            detail
        }
        .sheet(isPresented: $showsNewMeeting) {
            NewMeetingSheet(defaults: store.settings)
        }
        .onChange(of: session.meeting?.id) { _, id in
            if let id { selection = id }
        }
        // The live view asks after a long sleep or when the meeting looks
        // over, so it shows even if another meeting was open.
        .onChange(of: session.wakeQuestion != nil || session.offersFinish) { _, asks in
            if asks, let id = session.meeting?.id { selection = id }
        }
        .task {
            // The window also opens again mid-meeting; that meeting is fine.
            guard session.phase == .idle else { return }
            interrupted = store.recoverInterrupted().map { meeting in
                let lines = (try? store.transcriptLines(for: meeting.id)) ?? []
                return Interrupted(meeting: meeting, stoppedAt: meeting.recordedUntil(lines))
            }
        }
        .alert(interruptedTitle, isPresented: asksAboutInterrupted, presenting: interrupted.first) { item in
            Button("Lanjutkan merekam") { resume(item.meeting) }
                .keyboardShortcut(.defaultAction)
            Button("Selesaikan dan buat notulen") {
                selection = item.meeting.id
                Task { await session.finishInterrupted(item.meeting) }
            }
        } message: { item in
            Text("Rekaman berhenti pada \(MeetingTime.format(item.stoppedAt)).")
        }
        .safeAreaInset(edge: .bottom) {
            if let error = store.lastError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Tutup") { store.lastError = nil }
                }
                .padding(10)
                .background(.bar)
            }
        }
    }

    private var interruptedTitle: Text {
        let title = interrupted.first?.meeting.title ?? ""
        return Text("Meeting “\(title.isEmpty ? "Tanpa judul" : title)” terhenti tiba-tiba")
    }

    /// Answering one meeting moves on to the next.
    private var asksAboutInterrupted: Binding<Bool> {
        Binding {
            !interrupted.isEmpty
        } set: { shown in
            if !shown, !interrupted.isEmpty { interrupted.removeFirst() }
        }
    }

    private func resume(_ meeting: Meeting) {
        do {
            try session.resume(meeting)
        } catch {
            store.lastError = "Rekaman tidak bisa dilanjutkan: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let meeting = store.meetings.first(where: { $0.id == selection }) {
            if session.meeting?.id == meeting.id && session.phase != .idle {
                LiveMeetingView()
            } else if let step = finisher.running[meeting.id] {
                ProcessingView(meeting: meeting, step: step, steps: finisher.steps(for: meeting.id))
            } else {
                MinutesView(meeting: meeting)
                    .id(meeting.id)
            }
        } else if store.meetings.isEmpty {
            ContentUnavailableView {
                Label("Belum ada meeting", systemImage: "waveform")
            } description: {
                Text("Rekam meeting pertama untuk mendapat transkripnya.")
            } actions: {
                Button("Meeting Baru") { showsNewMeeting = true }
            }
        } else {
            Text("Pilih meeting")
                .foregroundStyle(.secondary)
        }
    }
}
