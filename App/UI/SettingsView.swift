import SwiftUI

/// Pengaturan (⌘,): Umum, AI, Notion and Tentang.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Umum", systemImage: "gearshape") }
            Form { AIProviderSection() }
                .formStyle(.grouped)
                .tabItem { Label("AI", systemImage: "sparkles") }
            NotionSettings()
                .tabItem { Label("Notion", systemImage: "doc.text") }
            AboutSettings()
                .tabItem { Label("Tentang", systemImage: "info.circle") }
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

/// The Notion integration: its token (Keychain) and the page that minutes
/// pages are created under.
private struct NotionSettings: View {
    @Environment(AppStore.self) private var store
    @ViewState private var tokenDraft = ""
    /// The page as typed, a URL or an ID; the store keeps the parsed ID.
    @ViewState private var pageDraft = ""

    private var pageIsInvalid: Bool {
        !pageDraft.trimmingCharacters(in: .whitespaces).isEmpty && NotionPageID.parse(pageDraft) == nil
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    SecureField(
                        "Token integrasi", text: $tokenDraft,
                        prompt: Text(store.hasNotionToken ? "Tersimpan. Tempel token baru untuk menggantinya" : "ntn_…"))
                        .onSubmit(saveToken)
                    Button("Simpan", action: saveToken)
                        .disabled(tokenDraft.isEmpty)
                    if store.hasNotionToken {
                        Button("Hapus", role: .destructive) { store.setNotionToken("") }
                    }
                }
                TextField("Halaman induk (URL atau ID)", text: $pageDraft)
                if pageIsInvalid {
                    Label("ID halaman tidak dikenali", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Notion")
            } footer: {
                Text("""
                    Buat integrasi internal di notion.so/profile/integrations, lalu bagikan halaman induk \
                    ke integrasi itu lewat menu ••• › Connections. Tiap meeting menjadi satu halaman di \
                    bawahnya; mengirim lagi memperbarui halaman yang sama. Token disimpan di Keychain.
                    """)
            }
        }
        .formStyle(.grouped)
        .onAppear { pageDraft = store.settings.notionParentPageID ?? "" }
        .onChange(of: pageDraft) {
            let id = NotionPageID.parse(pageDraft)
            let empty = pageDraft.trimmingCharacters(in: .whitespaces).isEmpty
            // A half-typed or wrong value stops sending until it's fixed.
            let stored = empty || id == nil ? nil : id
            if stored != store.settings.notionParentPageID { store.settings.notionParentPageID = stored }
        }
    }

    private func saveToken() {
        guard !tokenDraft.isEmpty else { return }
        store.setNotionToken(tokenDraft)
        tokenDraft = ""
    }
}

/// App version and the model attribution CC-BY-4.0 asks for.
private struct AboutSettings: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Notulen", value: "Versi \(version)")
            }
            Section {
                Text("Pemisahan pembicara memakai FluidAudio (Apache-2.0) dan model pyannote community-1 (CC-BY-4.0) dari pyannote, WeSpeaker, BUT Speech@FIT, dan Fluid Inference.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
