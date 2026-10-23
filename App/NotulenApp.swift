import SwiftUI

@main
struct NotulenApp: App {
    @ViewState private var store: AppStore
    @ViewState private var session: MeetingSession
    @ViewState private var showsNewMeeting = false

    init() {
        let store = AppStore()
        _store = ViewState(initialValue: store)
        _session = ViewState(initialValue: MeetingSession(store: store))
    }

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
