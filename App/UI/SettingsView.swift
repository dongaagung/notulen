import SwiftUI

/// Pengaturan (⌘,): Umum and AI. Notion and Tentang tabs come later.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Umum", systemImage: "gearshape") }
            Form { AIProviderSection() }
                .formStyle(.grouped)
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 560, height: 520)
    }
}

/// Defaults for new meetings, vocabulary and text size.
private struct GeneralSettings: View {
    @Environment(AppStore.self) private var store
    @ViewState private var apps: [AudioApp] = []
    @ViewState private var localeIDs: [String] = []
    /// The text as typed; the store keeps the cleaned-up terms. Binding the
    /// editor to them directly would eat each new blank line as it's typed.
    @ViewState private var vocabularyDraft = ""

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker("Bahasa", selection: $store.settings.localeIdentifier) {
                    ForEach(languageOptions, id: \.self) { id in
                        Text(Self.languageName(id)).tag(id)
                    }
                }
                Picker("Sumber audio", selection: $store.settings.meetingAudio) {
                    Text(MeetingAudioSource.systemWide.label).tag(MeetingAudioSource.systemWide)
                    if !sourceOptions.isEmpty { Divider() }
                    ForEach(sourceOptions, id: \.self) { source in
                        Text(source.label).tag(source)
                    }
                }
            } header: {
                Text("Meeting baru")
            } footer: {
                Text("Nilai awal di jendela Meeting Baru; bisa diubah per meeting.")
            }

            Section {
                TextEditor(text: $vocabularyDraft)
                    .font(.body)
                    .frame(minHeight: 90)
            } header: {
                Text("Kosakata")
            } footer: {
                Text("Satu istilah per baris: nama orang, produk atau singkatan yang sering salah dikenali.")
            }

            Section {
                LabeledContent("Ukuran teks") {
                    TextSizeControl(scale: $store.settings.textScale)
                }
            } footer: {
                Text("Berlaku untuk catatan, transkrip dan notulen. Juga lewat ⌘+, ⌘− dan ⌘0.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            apps = AudioProcessList.apps()
            vocabularyDraft = store.settings.vocabulary.joined(separator: "\n")
        }
        .onChange(of: vocabularyDraft) {
            let terms = vocabularyDraft.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if terms != store.settings.vocabulary { store.settings.vocabulary = terms }
        }
        .task {
            localeIDs = await SpeechAnalyzerProvider.supportedLocales().map { $0.identifier(.bcp47) }
        }
    }

    /// Apps using audio, plus the chosen app even when it isn't running now.
    private var sourceOptions: [MeetingAudioSource] {
        var options = apps.map { MeetingAudioSource.app(bundleID: $0.bundleID, name: $0.name) }
        let chosen = store.settings.meetingAudio
        if case .app = chosen, !options.contains(chosen) {
            options.insert(chosen, at: 0)
        }
        return options
    }

    /// Supported languages by their Indonesian name, plus the chosen one
    /// while the list loads.
    private var languageOptions: [String] {
        var ids = Set(localeIDs)
        ids.insert(store.settings.localeIdentifier)
        return ids.sorted { Self.languageName($0).localizedStandardCompare(Self.languageName($1)) == .orderedAscending }
    }

    private static let indonesian = Locale(identifier: "id_ID")

    private static func languageName(_ id: String) -> String {
        indonesian.localizedString(forIdentifier: id) ?? id
    }
}
