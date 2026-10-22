import SwiftUI

struct ContentView: View {
    @Environment(\.textScale) private var scale

    var body: some View {
        NavigationSplitView {
            List {}
        } detail: {
            Text("Belum ada meeting")
                .font(.scaled(.title2, scale))
                .foregroundStyle(.secondary)
        }
    }
}
