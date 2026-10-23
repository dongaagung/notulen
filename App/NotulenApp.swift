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

    /// While recording, asks first. Keluar saves the meeting as interrupted
    /// (the next launch offers to resume it), then quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch session.phase {
        case .idle:
            return .terminateNow
        case .starting:
            // Nothing recorded yet.
            session.cancelStart()
            return .terminateNow
        case .stopping:
            Task {
                await saveBeforeQuitting()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .recording:
            Task {
                let quit = await confirmQuit()
                if quit { await saveBeforeQuitting() }
                NSApp.reply(toApplicationShouldTerminate: quit)
            }
            return .terminateLater
        }
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

    private func confirmQuit() async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Meeting sedang direkam. Keluar sekarang?"
        alert.addButton(withTitle: "Keluar")
        alert.addButton(withTitle: "Batal").keyEquivalent = "\u{1b}"
        if let window = NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) {
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
