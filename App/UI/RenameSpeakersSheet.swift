import SwiftUI

/// Names the remote speakers and merges two that are the same person. Each
/// speaker shows a few of their longest lines with the time, and the AI's
/// guess at their name, if it has one. Names are saved with Selesai, and
/// when the sheet goes any other way (Esc); a merge or "Pakai" applies at
/// once. Everything is applied to the meeting as the store has it now, so
/// changes made meanwhile aren't overwritten.
struct RenameSpeakersSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let meetingID: UUID
    let lines: [TranscriptLine]
    /// Names as typed, by speaker.
    @ViewState private var drafts: [SpeakerID: String] = [:]

    var body: some View {
        if let meeting = store.meeting(meetingID) {
            let people = Self.speakers(of: meeting, lines: lines)
            VStack(alignment: .leading, spacing: 0) {
                Text("Ganti Nama Pembicara")
                    .font(.title3.weight(.semibold))
                    .padding([.horizontal, .top], 20)
                if people.isEmpty {
                    Text("Belum ada pembicara yang bisa diberi nama.")
                        .foregroundStyle(.secondary)
                        .padding(20)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(people, id: \.self) { row($0, meeting: meeting, people: people) }
                        }
                        .padding(20)
                    }
                }
                HStack {
                    Spacer()
                    Button("Selesai") {
                        commit()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding([.horizontal, .bottom], 20)
            }
            .frame(width: 520, height: 560)
            .onAppear {
                for id in people where drafts[id] == nil {
                    drafts[id] = meeting.hasName(id) ? meeting.displayName(for: id) : ""
                }
            }
            // Saves nothing when nothing changed, as after Selesai.
            .onDisappear { commit() }
        }
    }

    /// The remote speakers with a line, after merges, in number order.
    static func speakers(of meeting: Meeting, lines: [TranscriptLine]) -> [SpeakerID] {
        ParticipantChips.participants(of: meeting, lines: lines).filter { $0.remoteNumber != nil }
    }

    private func row(_ id: SpeakerID, meeting: Meeting, people: [SpeakerID]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Pembicara \(id.remoteNumber ?? 0)")
                    .font(.headline)
                    .frame(width: 100, alignment: .leading)
                TextField("Nama", text: draft(id), prompt: Text("Pembicara \(id.remoteNumber ?? 0)"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commit() }
                mergeMenu(id, meeting: meeting, people: people)
            }
            ForEach(meeting.sampleLines(for: id, in: lines, count: 3)) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(MeetingTime.format(line.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text("“\(line.text)”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            ForEach(hints(for: id, meeting: meeting), id: \.name) { hint in
                HStack(spacing: 8) {
                    Text("Mungkin \(hint.name): \(hint.evidence)")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Pakai") { use(hint, for: id) }
                        .controlSize(.small)
                }
            }
        }
    }

    private func mergeMenu(_ id: SpeakerID, meeting: Meeting, people: [SpeakerID]) -> some View {
        let targets = meeting.mergeTargets(for: id, among: people)
        return Menu("Gabungkan ke…") {
            ForEach(targets, id: \.self) { target in
                Button(label(target, meeting: meeting)) { merge(id, into: target) }
            }
        }
        .fixedSize()
        .disabled(targets.isEmpty)
    }

    private func label(_ id: SpeakerID, meeting: Meeting) -> String {
        let typed = drafts[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return typed.isEmpty ? meeting.displayName(for: id) : typed
    }

    private func hints(for id: SpeakerID, meeting: Meeting) -> [Minutes.NameHint] {
        let typed = drafts[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (meeting.minutes?.speakerNameHints ?? []).filter {
            meeting.resolved($0.speaker) == id && $0.name != typed
        }
    }

    private func draft(_ id: SpeakerID) -> Binding<String> {
        Binding { drafts[id] ?? "" } set: { drafts[id] = $0 }
    }

    // MARK: Actions

    /// Saves names that were typed, on the meeting as it is now.
    private func commit() {
        guard var latest = store.meeting(meetingID) else { return }
        let before = latest
        for (id, typed) in drafts {
            let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            let current = latest.hasName(id) ? latest.displayName(for: id) : ""
            if name != current { latest.rename(id, to: name) }
        }
        if latest != before { store.save(latest) }
    }

    private func use(_ hint: Minutes.NameHint, for id: SpeakerID) {
        drafts[id] = hint.name
        commit()
    }

    private func merge(_ from: SpeakerID, into target: SpeakerID) {
        commit()
        guard var latest = store.meeting(meetingID) else { return }
        latest.merge(from, into: target)
        store.save(latest)
        drafts[from] = nil
        // The target may have taken `from`'s name; an empty draft would
        // clear it on the next save.
        let merged = latest.resolved(target)
        if latest.hasName(merged), drafts[merged]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            drafts[merged] = latest.displayName(for: merged)
        }
    }
}
