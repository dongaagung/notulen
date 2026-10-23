import AppKit
import FluidAudio
import SwiftUI

@main
struct NotulenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var showsNewMeeting = false

    private var store: AppStore { delegate.store }
    private var session: MeetingSession { delegate.session }
    private var finisher: MeetingFinisher { delegate.finisher }

    init() {
        // The models ship inside the app; never download them.
        ModelHub.offlineMode = true
    }

    var body: some Scene {
        WindowGroup("Notulen") {
            ContentView(showsNewMeeting: $showsNewMeeting)
                .environment(store)
                .environment(session)
                .environment(finisher)
                .environment(\.textScale, store.settings.textScale)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Meeting Baru") { showsNewMeeting = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            // A menu shortcut, so it works only while Notulen is active.
            CommandGroup(after: .newItem) {
                MicCommand(session: session)
            }
            CommandGroup(after: .toolbar) {
                Button("Perbesar Teks") {
                    store.settings.textScale = TextScale.bigger(than: store.settings.textScale)
                }
                .keyboardShortcut("=", modifiers: .command)
                Button("Perkecil Teks") {
                    store.settings.textScale = TextScale.smaller(than: store.settings.textScale)
                }
                .keyboardShortcut("-", modifiers: .command)
                Button("Ukuran Asli") {
                    store.settings.textScale = TextScale.standard
                }
                .keyboardShortcut("0", modifiers: .command)
                Divider()
                TranscriptCommand()
                Divider()
            }
        }

        Settings {
            SettingsView()
                .environment(store)
                .environment(\.textScale, store.settings.textScale)
        }
    }
}

/// Matikan Mic / Nyalakan Mic (⇧⌘M), while a meeting records. A view of its
/// own, so the title and state follow the session.
private struct MicCommand: View {
    let session: MeetingSession

    var body: some View {
        Button(session.isMicOn ? "Matikan Mic" : "Nyalakan Mic") {
            session.setMicEnabled(!session.isMicOn)
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(session.phase != .recording)
    }
}

/// Tampilkan Transkrip / Sembunyikan Transkrip (⌥⌘T): the live view's
/// transcript inspector, in the window in front.
private struct TranscriptCommand: View {
    @FocusedBinding(\.showsTranscript) private var showsTranscript

    var body: some View {
        Button(showsTranscript == true ? "Sembunyikan Transkrip" : "Tampilkan Transkrip") {
            showsTranscript?.toggle()
        }
        .keyboardShortcut("t", modifiers: [.command, .option])
        .disabled(showsTranscript == nil)
    }
}

/// Owns the store, the finisher and the session, so quitting can ask first
/// while a meeting records.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: AppStore
    let finisher: MeetingFinisher
    let session: MeetingSession

    override init() {
        let store = AppStore()
        // Minutes a quit or crash cut off: Coba lagi writes them.
        store.recoverUnfinishedMinutes()
        self.store = store
        finisher = MeetingFinisher(store: store)
        session = MeetingSession(store: store, finisher: finisher)
        super.init()
    }

    /// Asks first while quitting would lose something: a meeting being
    /// recorded (Keluar saves it as interrupted, to resume at the next
    /// launch), or speaker separation still running (the meeting audio is
    /// only in RAM). Writing minutes just stops: the next launch offers Coba
    /// lagi.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch session.phase {
        case .idle, .starting:
            guard separatesSpeakers else {
                // A start still getting ready has recorded nothing yet.
                session.cancelStart()
                return .terminateNow
            }
        case .recording, .stopping:
            break
        }
        Task {
            let quit = await confirmQuit()
            if quit { await saveBeforeQuitting() }
            NSApp.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }

    /// One question before quitting: Keluar or Batal.
    struct QuitQuestion: Equatable {
        var message: String
        var detail: String?
    }

    /// What to ask before quitting, in order: whether to stop the recording,
    /// then whether to stop telling speakers apart. None: quit at once.
    static func quitQuestions(recording: Bool, steps: some Sequence<MeetingFinisher.Step>) -> [QuitQuestion] {
        var questions: [QuitQuestion] = []
        if recording {
            questions.append(QuitQuestion(message: "Meeting sedang direkam. Keluar sekarang?"))
        }
        if steps.contains(.separatingSpeakers) {
            questions.append(QuitQuestion(
                message: "Pemisahan pembicara sedang berjalan. Keluar sekarang?",
                detail: "Semua suara peserta akan berlabel “Lainnya”."))
        }
        return questions
    }

    private var separatesSpeakers: Bool {
        finisher.running.values.contains(.separatingSpeakers)
    }

    /// Asks each question quitting raises now; false once the owner picks
    /// Batal.
    private func confirmQuit() async -> Bool {
        // Selesai is saving the meeting (3 s at most); separating its
        // speakers comes next.
        while session.phase == .stopping { try? await Task.sleep(for: .milliseconds(100)) }
        let questions = Self.quitQuestions(recording: session.phase == .recording, steps: finisher.running.values)
        for question in questions {
            guard await ask(question) else { return false }
        }
        return true
    }

    /// Leaves the meeting saved, whatever the session got to while the
    /// owner was asked.
    private func saveBeforeQuitting() async {
        switch session.phase {
        case .idle:
            break
        case .starting:
            // Nothing recorded yet.
            session.cancelStart()
        case .recording:
            await session.interrupt()
        case .stopping:
            // Selesai is saving the meeting (3 s at most).
            while session.phase == .stopping { try? await Task.sleep(for: .milliseconds(100)) }
        }
    }

    /// True for Keluar.
    private func ask(_ question: QuitQuestion) async -> Bool {
        let alert = NSAlert()
        alert.messageText = question.message
        if let detail = question.detail { alert.informativeText = detail }
        alert.addButton(withTitle: "Keluar")
        alert.addButton(withTitle: "Batal").keyEquivalent = "\u{1b}"
        if let window = NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) {
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
