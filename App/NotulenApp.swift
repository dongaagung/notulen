import SwiftUI

@main
struct NotulenApp: App {
    // Held here until AppStore exists and takes over the saved text size.
    @ViewState private var textScale = TextScale.standard

    var body: some Scene {
        WindowGroup("Notulen") {
            ContentView()
                .environment(\.textScale, textScale)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Perbesar Teks") {
                    textScale = TextScale.bigger(than: textScale)
                }
                .keyboardShortcut("=", modifiers: .command)
                Button("Perkecil Teks") {
                    textScale = TextScale.smaller(than: textScale)
                }
                .keyboardShortcut("-", modifiers: .command)
                Button("Ukuran Asli") {
                    textScale = TextScale.standard
                }
                .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
        }
    }
}
