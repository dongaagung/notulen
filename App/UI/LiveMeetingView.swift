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
    nonisolated static let columnWidth: CGFloat = 620
    /// Below this the column gives up its wide margins.
    nonisolated static let narrowColumn: CGFloat = 480

    /// Room on each side of the column: 40 pt, or 16 pt where 40 would leave
    /// the column narrower than `narrowColumn`, as with the sidebar and the
    /// transcript both open in a small window.
    nonisolated static func sidePadding(forWidth width: CGFloat) -> CGFloat {
        width - 2 * 40 < narrowColumn ? 16 : 40
    }

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
                    .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
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
            ReadingColumn {
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
            }
            .padding(.top, 30)
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .top, spacing: 0) { banners }
        .safeAreaInset(edge: .bottom, spacing: 0) { LiveStrip() }
        .textScalePinch(textScale)
        .background { Color.canvas.ignoresSafeArea() }
    }

    /// What the start is doing, then the notices; as wide as the column.
    private var banners: some View {
        ReadingColumn {
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
        }
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

    /// Why no live notes are coming: what the AI provider still needs (the
    /// notes start within 10 s of it being ready), or why the session can't
    /// make them. Nil while they come, so only then the notes promise the
    /// first ones.
    private var notesProblem: String? {
        store.aiProblem ?? session.liveNotesProblem
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

/// One reading column, centered in the width it's offered: at most
/// `LiveMeetingView.columnWidth` wide, with
/// `LiveMeetingView.sidePadding(forWidth:)` on each side, its content
/// leading. The margins come from the offered width, never a measured one:
/// a measured width moved the view's minimum width with each layout, and
/// the split view holding it laid it out again, at a passing narrow width,
/// over and over until AppKit gave up.
struct ReadingColumn: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let (padding, width) = Self.column(in: proposal.width)
        let size = content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        let needed = size.width + 2 * padding
        return CGSize(width: max(proposal.width ?? needed, needed), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let (_, width) = Self.column(in: bounds.width)
        content.place(
            at: CGPoint(x: bounds.midX - width / 2, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: bounds.height))
    }

    /// The column is never measured narrower than this. SwiftUI asks for a
    /// view's minimum size at no width, and wrapped text measured at nothing
    /// is a character per line, 1500 pt tall: that became the minimum height
    /// of the whole column, taller than the window. An 820 pt window with
    /// the sidebar at 240 and the inspector at 360 leaves this much.
    nonisolated static let narrowest: CGFloat = 220

    /// The margin on each side and the column's width for an offered width;
    /// with none offered, the widest column.
    static func column(in offered: CGFloat?) -> (padding: CGFloat, width: CGFloat) {
        let offered = max(offered ?? .infinity, narrowest)
        let padding = LiveMeetingView.sidePadding(forWidth: offered)
        return (padding, min(LiveMeetingView.columnWidth, offered - 2 * padding))
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
            TranscriptView(
                transcript: session.transcript, gaps: session.meeting?.gaps ?? [],
                micOff: session.endedMicOffPeriods)
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
