import SwiftUI

/// Title, audio source and language for a new meeting, then Mulai. Source
/// and language start from the defaults in Pengaturan.
struct NewMeetingSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(MeetingSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @ViewState private var title = ""
    @ViewState private var audioSource: MeetingAudioSource
    /// BCP 47, like `AppSettings.localeIdentifier`.
    @ViewState private var localeID: String
    @ViewState private var apps: [AudioApp] = []
    @ViewState private var localeIDs: [String] = []
    @ViewState private var error: String?

    init(defaults settings: AppSettings) {
        _audioSource = ViewState(initialValue: settings.meetingAudio)
        _localeID = ViewState(initialValue: settings.localeIdentifier)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Meeting Baru")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 20)
            Form {
                TextField("Judul", text: $title, prompt: Text("Tanpa judul"))
                Picker("Sumber audio", selection: $audioSource) {
                    Text(MeetingAudioSource.systemWide.label).tag(MeetingAudioSource.systemWide)
                    if !sourceOptions.isEmpty { Divider() }
                    ForEach(sourceOptions, id: \.self) { source in
                        Text(source.label).tag(source)
                    }
                }
                Picker("Bahasa", selection: $localeID) {
                    ForEach(languageOptions, id: \.self) { id in
                        Text(Self.languageName(id)).tag(id)
                    }
                }
            }
            .padding(20)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button("Batal", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Mulai", action: start)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 440)
        .onAppear { apps = AudioProcessList.apps() }
        .task {
            localeIDs = await SpeechAnalyzerProvider.supportedLocales().map { $0.identifier(.bcp47) }
        }
    }

    private func start() {
        let configuration = MeetingSession.Configuration(
            title: title, audioSource: audioSource,
            locale: Locale(identifier: localeID), vocabulary: store.settings.vocabulary)
        do {
            try session.begin(configuration)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Apps using audio (playing ones first), plus the chosen app even when
    /// it isn't running now.
    private var sourceOptions: [MeetingAudioSource] {
        var options = apps.map { MeetingAudioSource.app(bundleID: $0.bundleID, name: $0.name) }
        if case .app = audioSource, !options.contains(audioSource) {
            options.insert(audioSource, at: 0)
        }
        return options
    }

    /// Supported languages by their Indonesian name, plus the chosen one
    /// while the list loads.
    private var languageOptions: [String] {
        var ids = Set(localeIDs)
        ids.insert(localeID)
        return ids.sorted { Self.languageName($0).localizedStandardCompare(Self.languageName($1)) == .orderedAscending }
    }

    private static let indonesian = Locale(identifier: "id_ID")

    /// "Inggris (Amerika Serikat)" for "en-US".
    private static func languageName(_ id: String) -> String {
        indonesian.localizedString(forIdentifier: id) ?? id
    }
}
