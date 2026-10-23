import AppKit
import SwiftUI

@main
struct NotulenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ViewState private var showsNewMeeting = false

    private var store: AppStore { delegate.store }
    private var session: MeetingSession { delegate.session }

    var body: some Scene {
        WindowGroup("Notulen") {
            ContentView(showsNewMeeting: $showsNewMeeting)
                .environment(store)
                .environment(session)
                .environment(\.textScale, store.settings.textScale)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Meeting Baru") { showsNewMeeting = true }
                    .keyboardShortcut("n", modifiers: .command)
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
            }
        }
    }
}

/// Owns the store and the session, so quitting can ask first while a
/// meeting records.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: AppStore
    let session: MeetingSession

    override init() {
        let store = AppStore()
        self.store = store
        session = MeetingSession(store: store)
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
            // Selesai is saving the meeting; quit once it's saved (3 s at most).
            Task {
                while session.phase == .stopping { try? await Task.sleep(for: .milliseconds(100)) }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .recording:
            Task {
                let quit = await confirmQuit()
                if quit { await session.interrupt() }
                NSApp.reply(toApplicationShouldTerminate: quit)
            }
            return .terminateLater
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
