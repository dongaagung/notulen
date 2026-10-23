import AppKit
import SwiftUI

/// The meeting being recorded. The toolbar has the title, the recording
/// capsule, the mic button, text size, the transcript toggle (⌥⌘T) and
/// Selesai. Below, the live notes read in one column, notices stack on top,
/// and a glass strip shows the last thing said; the full transcript opens
/// in the inspector. Asks what to do after a long sleep, and offers to
/// finish once the meeting looks over.
struct LiveMeetingView: View {
    @Environment(AppStore.self) private var store
    @Environment(MeetingSession.self) private var session
    @Environment(\.textScale) private var scale
    /// The transcript inspector; the menu's Tampilkan Transkrip (⌥⌘T) too.
    @ViewState private var showsTranscript = false

    static let finishOffer = "Meeting sepertinya sudah selesai. Selesaikan rekaman?"

    /// The notes read at most this wide.
    static let columnWidth: CGFloat = 620

    /// ⇧⌘M is the app menu's Matikan Mic / Nyalakan Mic.
    static func micToggleHelp(micOn: Bool) -> String {
        micOn ? "Matikan mic (⇧⌘M)" : "Nyalakan mic (⇧⌘M)"
    }

    /// Asked when the Mac woke after sleeping longer than `WakePolicy.resumeLimit`.
    static func wakeQuestion(sleptFor duration: TimeInterval, title: String) -> String {
        "Mac tidur selama \(MeetingTime.duration(duration)). Lanjutkan merekam “\(title)” atau Selesaikan?"
    }

    /// "Zoom · Bahasa Indonesia · AirPods Pro"; no mic while its name is unknown.
    static func metaLine(source: MeetingAudioSource, language: String, mic: String?) -> String {
        var parts = [source.label, languageName(language)]
        if let mic, !mic.isEmpty { parts.append(mic) }
        return parts.joined(separator: " · ")
    }

    /// "Bahasa Indonesia" for "id-ID", "Bahasa Inggris" for "en-US".
    static func languageName(_ bcp47: String) -> String {
        guard let code = Locale(identifier: bcp47).language.languageCode?.identifier,
              let name = Locale(identifier: "id_ID").localizedString(forLanguageCode: code)
        else { return bcp47 }
        return "Bahasa \(name)"
    }

    var body: some View {
        notes
            // Not on the same view as the wake question: one view, one alert.
            .alert(Self.finishOffer, isPresented: offersFinish) {
                // Task.immediate: the offer is gone before the alert closes.
                Button("Selesai") { Task.immediate { _ = await session.stop() } }
                Button("Tetap merekam", role: .cancel) { session.declineFinishOffer() }
            }
            .inspector(isPresented: $showsTranscript) {
                InspectorTranscript()
                    .textScalePinch(textScale)
                    .inspectorColumnWidth(min: 240, ideal: 300, max: 480)
            }
            .alert(Self.wakeQuestion(sleptFor: session.wakeQuestion ?? 0, title: title), isPresented: asksAfterWake) {
                // No cancel: nothing records until the owner picks one.
                Button("Lanjutkan") { Task.immediate { await session.answerWake(continueRecording: true) } }
                    .keyboardShortcut(.defaultAction)
                Button("Selesaikan") { Task.immediate { await session.answerWake(continueRecording: false) } }
            }
            .navigationTitle(title)
            .toolbar { toolbar }
            .focusedSceneValue(\.showsTranscript, $showsTranscript)
    }

    /// One reading column, centered: where the audio comes from, then the notes.
    private var notes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let meta {
                    Text(meta)
                        .font(.scaled(.callout, scale))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 26 * scale)
                }
                LiveNotesView(
                    notes: session.meeting?.liveNotes, updatedAt: session.meeting?.liveNotesUpdatedAt,
                    problem: notesProblem)
            }
            .frame(maxWidth: Self.columnWidth, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) { banners }
        .safeAreaInset(edge: .bottom, spacing: 0) { LiveStrip() }
        .textScalePinch(textScale)
        .background { Color.canvas.ignoresSafeArea() }
    }

    /// What the start is doing, then the notices; as wide as the column.
    private var banners: some View {
        VStack(spacing: 0) {
            if let status = session.startupStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .padding(.top, 8)
            }
            NoticeBanner(notices: session.notices)
        }
        .frame(maxWidth: Self.columnWidth)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Separate glass groups, as in the mockup.
        if session.phase != .starting {
            ToolbarItem(placement: .primaryAction) { RecordingCapsule() }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { micToggle }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) { TextSizeControl(scale: textScale) }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) { transcriptToggle }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) { finishButton }
    }

    private var title: String {
        let title = session.meeting?.title ?? ""
        return title.isEmpty ? "Tanpa judul" : title
    }

    private var meta: String? {
        guard let meeting = session.meeting else { return nil }
        return Self.metaLine(source: meeting.audioSource, language: meeting.language, mic: session.micName)
    }

    /// Why no live notes are coming: without a usable AI provider the
    /// session makes no updater.
    private var notesProblem: String? {
        session.liveNotes == nil ? store.aiProblem : nil
    }

    private var textScale: Binding<Double> {
        Binding { store.settings.textScale } set: { store.settings.textScale = $0 }
    }

    /// The buttons answer; the session then clears the question.
    private var asksAfterWake: Binding<Bool> {
        Binding { session.wakeQuestion != nil } set: { _ in }
    }

    /// The buttons answer; the session then clears the offer.
    private var offersFinish: Binding<Bool> {
        Binding { session.offersFinish } set: { _ in }
    }

    /// Off keeps the owner's side talk out of the transcript; the meeting
    /// audio records on.
    private var micToggle: some View {
        Button {
            session.setMicEnabled(!session.isMicOn)
        } label: {
            Label(
                session.isMicOn ? "Matikan Mic" : "Nyalakan Mic",
                systemImage: session.isMicOn ? "mic" : "mic.slash")
        }
        .help(Self.micToggleHelp(micOn: session.isMicOn))
        .disabled(session.phase != .recording)
    }

    private var transcriptToggle: some View {
        Toggle(isOn: $showsTranscript) {
            Label("Transkrip", systemImage: "sidebar.right")
        }
        .toggleStyle(.button)
        .help(showsTranscript ? "Sembunyikan transkrip (⌥⌘T)" : "Tampilkan transkrip (⌥⌘T)")
    }

    /// Selesai while recording; Batal while the start is still getting ready.
    @ViewBuilder
    private var finishButton: some View {
        switch session.phase {
        case .starting:
            Button("Batal") { session.cancelStart() }
                .help("Batalkan meeting ini")
        case .recording:
            Button("Selesai") {
                Task { _ = await session.stop() }
            }
            .buttonStyle(.borderedProminent)
            .help("Hentikan rekaman")
        case .stopping:
            ProgressView().controlSize(.small)
        case .idle:
            EmptyView()
        }
    }
}

/// The transcript in the inspector. Reads it on its own, so new words
/// redraw only this panel.
private struct InspectorTranscript: View {
    @Environment(MeetingSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Transkrip")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 16)
            TranscriptView(transcript: session.transcript)
        }
    }
}

// `@Entry` would be shorter, but it's a macro whose plugin needs Xcode.
/// The live view's transcript inspector, for the menu's Tampilkan Transkrip.
struct ShowsTranscriptKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var showsTranscript: Binding<Bool>? {
        get { self[ShowsTranscriptKey.self] }
        set { self[ShowsTranscriptKey.self] = newValue }
    }
}

extension Color {
    /// Behind the notes: neutral #F6F6F6 in light mode; dark follows the system.
    static let canvas = Color(nsColor: .underPageBackgroundColor)
    /// A card on `canvas`: white in light mode, a shade lighter than the canvas in dark.
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.06) : .white
    })
}
