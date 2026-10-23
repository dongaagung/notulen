import SwiftUI
import UniformTypeIdentifiers

/// A meeting that has ended: its minutes, or why there are none, and its
/// transcript, switched with Notulen | Transkrip in the toolbar. One reading
/// column: when and where, the editable title, who took part, then the
/// minutes. Ticking an action item saves at once; a time opens the
/// transcript at that point, highlighted.
struct MinutesView: View {
    @Environment(AppStore.self) private var store
    @Environment(MeetingFinisher.self) private var finisher
    @Environment(MeetingSession.self) private var session
    @Environment(\.textScale) private var scale
    let meeting: Meeting

    enum Tab: Hashable {
        case minutes, transcript
    }

    @ViewState private var tab = Tab.minutes
    /// The meeting's journal, in time order.
    @ViewState private var lines: [TranscriptLine] = []
    /// The line the last time clicked points at.
    @ViewState private var focus: TranscriptLine.ID?
    /// The title as typed; saved when editing ends.
    @ViewState private var title: String
    @FocusState private var editsTitle: Bool
    @ViewState private var confirmsRegenerate = false
    @ViewState private var renamesSpeakers = false
    /// The language shown, a BCP 47 code; "id" is the minutes as written.
    @ViewState private var language = "id"
    @ViewState private var choosesLanguage = false
    /// "Disalin" shows for a moment after the minutes were copied.
    @ViewState private var copied = false
    /// A PDF is being written; another export waits for it.
    @ViewState private var exportsPDF = false
    /// The journal has been read, so an empty `lines` means nothing was said.
    @ViewState private var linesLoaded = false
    /// The page's width, for `LiveMeetingView.sidePadding(forWidth:)`.
    @ViewState private var width = CGFloat.infinity

    static let regenerateTitle = "Buat ulang notulen?"
    static let regenerateMessage = "Centang action item dan terjemahan yang ada akan dihapus."
    /// The "Terjemahkan ke" menu: name and code.
    static let translationLanguages: [(name: String, code: String)] = [
        ("Inggris", "en"), ("Mandarin", "zh-Hans"), ("Jepang", "ja"), ("Korea", "ko"), ("Arab", "ar"),
        ("Belanda", "nl"), ("Jerman", "de"), ("Prancis", "fr"), ("Spanyol", "es"),
    ]
    static let notStarted = "Rekaman tidak sempat dimulai."
    static let nothingRecorded = "Tidak ada percakapan yang terekam."

    init(meeting: Meeting) {
        self.meeting = meeting
        _title = ViewState(initialValue: meeting.title)
    }

    /// "Kamis, 22 Oktober 2026 · 09.00–10.12 · 1 jam 12 menit · Zoom ·
    /// Bahasa Indonesia"; just the start time while it has no end.
    static func metaLine(_ meeting: Meeting, timeZone: TimeZone = .current) -> String {
        let locale = Locale(identifier: "id_ID")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = Date.FormatStyle(date: .complete, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone)
        // "09.00": the locale's short time drops the leading zero.
        let time = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        var parts = [meeting.startedAt.formatted(day)]
        if let end = meeting.endedAt {
            parts.append("\(meeting.startedAt.formatted(time))–\(end.formatted(time))")
            parts.append(MeetingTime.duration(end.timeIntervalSince(meeting.startedAt)))
        } else {
            parts.append(meeting.startedAt.formatted(time))
        }
        parts.append(meeting.audioSource.label)
        parts.append(LiveMeetingView.languageName(meeting.language))
        return parts.joined(separator: " · ")
    }

    /// The line a time in the minutes points at: the last one to start by
    /// then, counting whole seconds as the AI read them ("[05:12]" for a line
    /// at 312.7 s), else the first.
    static func lineID(at time: TimeInterval, in lines: [TranscriptLine]) -> TranscriptLine.ID? {
        let ordered = lines.sorted { $0.start < $1.start }
        return (ordered.last { $0.start.rounded(.down) <= time } ?? ordered.first)?.id
    }

    var body: some View {
        ZStack {
            // Kept while the transcript shows, so the minutes stay where the
            // owner scrolled them.
            notesPage
                .opacity(tab == .minutes ? 1 : 0)
                .disabled(tab != .minutes)
                .accessibilityHidden(tab != .minutes)
            if tab == .transcript {
                TranscriptView(transcript: Transcript(lines: lines), finished: .init(meeting: meeting, focus: focus))
                    .textScalePinch(textScale)
                    .background { Color.canvas.ignoresSafeArea() }
            }
        }
        .overlay(alignment: .bottom) {
            if copied {
                Label("Disalin", systemImage: "checkmark")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 24)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.default, value: copied)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .milliseconds(1500))
            copied = false
        }
        .navigationTitle(meeting.title.isEmpty ? "Tanpa judul" : meeting.title)
        .toolbar { toolbar }
        .task(id: meeting.id) { await loadTranscript() }
        .onChange(of: meeting.title) {
            if !editsTitle { title = meeting.title }
        }
        .onChange(of: editsTitle) {
            if !editsTitle { saveTitle() }
        }
        .onChange(of: tab) { editsTitle = false }
        .onDisappear { saveTitle() }
        .sheet(isPresented: $renamesSpeakers) {
            RenameSpeakersSheet(meetingID: meeting.id, lines: lines)
        }
        .sheet(isPresented: $choosesLanguage) {
            LanguageCodeSheet { translate(to: $0) }
        }
        .confirmationDialog(Self.regenerateTitle, isPresented: $confirmsRegenerate, titleVisibility: .visible) {
            Button("Buat Ulang", role: .destructive) { regenerate() }
            Button("Batal", role: .cancel) {}
        } message: {
            Text(Self.regenerateMessage)
        }
    }

    // MARK: Minutes

    private var notesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.metaLine(meeting))
                    .font(.scaled(.callout, scale))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                titleField
                    .padding(.top, 6 * scale)
                    .padding(.bottom, 12 * scale)
                participants
                    .padding(.bottom, 30 * scale)
                content
            }
            .frame(maxWidth: LiveMeetingView.columnWidth, alignment: .leading)
            .padding(.horizontal, LiveMeetingView.sidePadding(forWidth: width))
            .padding(.top, 30)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .textScalePinch(textScale)
        .background { Color.canvas.ignoresSafeArea() }
    }

    private var participants: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ParticipantChips(meeting: meeting, lines: lines)
            if !RenameSpeakersSheet.speakers(of: meeting, lines: lines).isEmpty {
                Button("Ganti nama…") { renamesSpeakers = true }
                    .buttonStyle(.link)
                    .font(.scaled(.callout, scale))
            }
        }
    }

    private var titleField: some View {
        TextField("Judul", text: $title, prompt: Text("Tanpa judul"), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.scaled(.largeTitle, scale, weight: .bold))
            .focused($editsTitle)
            .onSubmit { editsTitle = false }
            .help("Ubah judul")
    }

    @ViewBuilder
    private var content: some View {
        switch meeting.status {
        case .ready:
            if let minutes = shownMinutes {
                MinutesSections(
                    minutes: minutes, meeting: meeting, jump: { jump(to: $0) }, toggle: { toggle($0) })
            } else {
                Label(Self.nothingRecorded, systemImage: "waveform.slash")
                    .font(.scaled(.title3, scale))
                    .foregroundStyle(.secondary)
            }
        case .failed, .processing:
            // Processing here means no finisher runs for it any more.
            VStack(alignment: .leading, spacing: 30 * scale) {
                failure(meeting.failure ?? AppStore.minutesCutOff)
                // A failed rewrite leaves the earlier minutes worth reading.
                if let minutes = shownMinutes {
                    MinutesSections(
                        minutes: minutes, meeting: meeting, jump: { jump(to: $0) }, toggle: { toggle($0) })
                }
            }
        case .interrupted, .recording:
            interrupted
        }
    }

    /// The translation for the language shown, else the minutes as written.
    private var shownLanguage: String {
        language != "id" && meeting.translations[language] != nil ? language : "id"
    }

    private var shownMinutes: Minutes? {
        shownLanguage == "id" ? meeting.minutes : meeting.translations[shownLanguage]
    }

    private func failure(_ reason: String) -> some View {
        panel {
            Label("Notulen belum bisa dibuat", systemImage: "exclamationmark.triangle")
                .font(.scaled(.title3, scale, weight: .semibold))
            Text(reason)
                .font(.scaled(.body, scale))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(hasTranscript ? "Transkripnya tetap utuh di tab Transkrip." : Self.notStarted)
                .font(.scaled(.callout, scale))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if hasTranscript {
                    Button("Coba lagi") { regenerate() }
                        .buttonStyle(.borderedProminent)
                }
                if store.aiProblem != nil {
                    SettingsLink { Text("Buka Pengaturan…") }
                }
            }
            .padding(.top, 4 * scale)
        }
    }

    /// False only once the journal has been read and is empty.
    private var hasTranscript: Bool { !linesLoaded || !lines.isEmpty }

    /// Left by a crash or quit, and neither resumed nor finished at launch.
    private var interrupted: some View {
        panel {
            Label("Rekaman meeting ini terhenti", systemImage: "pause.circle")
                .font(.scaled(.title3, scale, weight: .semibold))
            Text("Selesaikan untuk membuat notulen dari yang sudah terekam.")
                .font(.scaled(.body, scale))
                .foregroundStyle(.secondary)
            Button("Selesaikan dan buat notulen") {
                Task { await session.finishInterrupted(meeting) }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4 * scale)
        }
    }

    private func panel(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 16 * scale)
        .padding(.horizontal, 18)
        .background(Color.card, in: .rect(cornerRadius: 12))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Tampilan", selection: $tab) {
                Text("Notulen").tag(Tab.minutes)
                Text("Transkrip").tag(Tab.transcript)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        if finisher.translating[meeting.id] != nil {
            ToolbarItem(placement: .primaryAction) {
                ProgressView().controlSize(.small).help("Menerjemahkan…")
            }
        }
        if meeting.translations.keys.contains(where: { $0 != "id" }) {
            ToolbarItem(placement: .primaryAction) { languagePicker }
        }
        ToolbarItem(placement: .primaryAction) { TextSizeControl(scale: textScale) }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) { shareMenu }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) { moreMenu }
    }

    private var languagePicker: some View {
        Picker("Bahasa", selection: Binding { shownLanguage } set: { language = $0 }) {
            Text("Bahasa Indonesia").tag("id")
            ForEach(meeting.translations.keys.filter { $0 != "id" }.sorted(), id: \.self) { code in
                Text(Translator.languageName(code).map { "Bahasa \($0)" } ?? code).tag(code)
            }
        }
        .help("Bahasa notulen")
    }

    /// Exports the minutes in the language shown. Notion comes in a later task.
    private var shareMenu: some View {
        Menu {
            Button("Salin sebagai Markdown") { copyMarkdown() }
            Button("Ekspor PDF…") { exportPDF() }
                .disabled(exportsPDF)
        } label: {
            Label("Bagikan", systemImage: "square.and.arrow.up")
        }
        .menuIndicator(.hidden)
        .disabled(meeting.status != .ready || meeting.minutes == nil)
        .help("Bagikan")
    }

    private var moreMenu: some View {
        Menu {
            Menu("Terjemahkan ke") {
                ForEach(Self.translationLanguages, id: \.code) { item in
                    Button(item.name) { translate(to: item.code) }
                }
                Divider()
                Button("Bahasa lain…") { choosesLanguage = true }
            }
            .disabled(!canTranslate)
            Button("Buat ulang notulen") { confirmsRegenerate = true }
                .disabled(!canRegenerate)
            if meeting.minutes != nil, let problem = store.aiProblem {
                Text(problem)
            }
        } label: {
            Label("Lainnya", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("Lainnya")
    }

    private var canRegenerate: Bool {
        meeting.status == .ready && meeting.minutes != nil && store.isAIReady
            && finisher.running[meeting.id] == nil && finisher.translating[meeting.id] == nil
    }

    private var canTranslate: Bool { canRegenerate }

    // MARK: Actions

    private var textScale: Binding<Double> {
        Binding { store.settings.textScale } set: { store.settings.textScale = $0 }
    }

    private func copyMarkdown() {
        guard let minutes = shownMinutes else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(MinutesMarkdown.render(minutes, meeting: meeting), forType: .string)
        copied = true
    }

    /// Asks where to save, then writes the PDF there.
    private func exportPDF() {
        guard let minutes = shownMinutes else { return }
        let html = MinutesHTML.render(minutes, meeting: meeting)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = PDFExporter.fileName(
            title: MinutesFormatting.title(minutes, meeting: meeting), date: meeting.startedAt)
        Task {
            let response = if let window = NSApp.keyWindow {
                await panel.beginSheetModal(for: window)
            } else {
                panel.runModal()
            }
            guard response == .OK, let url = panel.url else { return }
            exportsPDF = true
            defer { exportsPDF = false }
            do {
                try await PDFExporter.export(html: html, to: url)
            } catch {
                store.lastError = "PDF tidak bisa diekspor: \(error.localizedDescription)"
            }
        }
    }

    private func translate(to code: String) {
        let id = meeting.id
        let code = Translator.normalized(code)
        Task {
            await finisher.translate(id, to: code)
            if store.meeting(id)?.translations[code] != nil { language = code }
        }
    }

    private func jump(to time: TimeInterval) {
        editsTitle = false
        focus = Self.lineID(at: time, in: lines)
        tab = .transcript
    }

    private func toggle(_ item: Minutes.ActionItem.ID) {
        guard var latest = store.meeting(meeting.id) else { return }
        if latest.actionItemsDone.remove(item) == nil {
            latest.actionItemsDone.insert(item)
        }
        store.save(latest)
    }

    /// One line; the meeting as it is now, in case the finisher saved it meanwhile.
    private func saveTitle() {
        let typed = title.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard var latest = store.meeting(meeting.id), latest.title != typed else { return }
        latest.title = typed
        store.save(latest)
    }

    private func regenerate() {
        let id = meeting.id
        Task { await finisher.regenerate(id) }
    }

    private func loadTranscript() async {
        guard let url = store.transcriptURL(for: meeting.id) else { return }
        defer { linesLoaded = true }
        do {
            lines = try await Task.detached {
                guard FileManager.default.fileExists(atPath: url.path) else { return [] }
                return try TranscriptJournal.read(url).sorted { $0.start < $1.start }
            }.value
        } catch {
            store.lastError = "Transkrip meeting ini tidak bisa dibaca: \(error.localizedDescription)"
        }
    }
}
