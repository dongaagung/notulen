import SwiftUI

struct ContentView: View {
    /// Set by the sidebar button and ⌘N.
    @Binding var showsNewMeeting: Bool
    @Environment(AppStore.self) private var store
    @Environment(MeetingSession.self) private var session
    @ViewState private var selection: Meeting.ID?

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

    @ViewBuilder
    private var detail: some View {
        if let meeting = store.meetings.first(where: { $0.id == selection }) {
            if session.meeting?.id == meeting.id && session.phase != .idle {
                LiveMeetingView()
            } else {
                SavedMeetingView(meeting: meeting)
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

/// A meeting that isn't recording, with the transcript from its journal.
/// Task 17 replaces it with the minutes.
private struct SavedMeetingView: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting
    @ViewState private var transcript = Transcript()

    var body: some View {
        VStack(spacing: 0) {
            if let failure = meeting.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                    .padding([.horizontal, .top], 20)
            }
            TranscriptView(transcript: transcript)
        }
        .navigationTitle(meeting.title.isEmpty ? "Tanpa judul" : meeting.title)
        .task {
            guard let url = store.transcriptURL(for: meeting.id),
                  FileManager.default.fileExists(atPath: url.path)
            else { return }
            do {
                transcript = Transcript(lines: try TranscriptJournal.read(url))
            } catch {
                store.lastError = "Transkrip meeting ini tidak bisa dibaca: \(error.localizedDescription)"
            }
        }
    }
}
