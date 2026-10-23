import SwiftUI

/// The minutes' sections: Ringkasan, Keputusan, Action item, Pertanyaan
/// terbuka and Topik yang dibahas. Speakers go by their current names; a
/// time (in blue) opens the transcript there.
struct MinutesSections: View {
    let minutes: Minutes
    let meeting: Meeting
    /// Opens the transcript at a meeting time.
    let jump: (TimeInterval) -> Void
    /// Ticks an action item off, or back on.
    let toggle: (Minutes.ActionItem.ID) -> Void
    @Environment(\.textScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 30 * scale) {
            section("Ringkasan") {
                if minutes.summary.isEmpty {
                    none("Tidak ada ringkasan.")
                } else {
                    Text(meeting.named(minutes.summary))
                        .font(.scaled(.body, scale))
                        .lineSpacing(3 * scale)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            section("Keputusan", count: minutes.decisions.count) {
                card(minutes.decisions, empty: "Tidak ada keputusan.") { decision in
                    row(
                        Image(systemName: "diamond.fill").font(.scaled(.caption, scale)),
                        text: decision.text, detail: nil, at: decision.at)
                }
            }
            section("Action item", count: minutes.actionItems.count) {
                card(minutes.actionItems, empty: "Tidak ada action item.") { item in
                    ActionItemRow(
                        item: item, meeting: meeting, isDone: meeting.actionItemsDone.contains(item.id),
                        toggle: { toggle(item.id) }, jump: jump)
                }
            }
            section("Pertanyaan terbuka", count: minutes.openQuestions.count) {
                card(minutes.openQuestions, empty: "Tidak ada pertanyaan terbuka.") { question in
                    row(
                        Image(systemName: "questionmark").font(.scaled(.callout, scale, weight: .semibold)),
                        text: question.question, detail: question.context, at: question.at)
                }
            }
            section("Topik yang dibahas", count: minutes.topics.count) {
                if minutes.topics.isEmpty {
                    none("Tidak ada topik.")
                } else {
                    VStack(alignment: .leading, spacing: 18 * scale) {
                        ForEach(minutes.topics.indices, id: \.self) { index in
                            topic(minutes.topics[index], number: index + 1)
                        }
                    }
                }
            }
        }
    }

    private func section(_ title: String, count: Int? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.scaled(.title2, scale, weight: .bold))
                if let count, count > 0 {
                    Text(String(count))
                        .font(.scaled(.callout, scale, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func none(_ text: String) -> some View {
        Text(text)
            .font(.scaled(.body, scale))
            .foregroundStyle(.secondary)
    }

    /// Rows on a card, with hairlines between. By position: the AI's IDs
    /// may repeat.
    @ViewBuilder
    private func card<Item>(_ items: [Item], empty: String, @ViewBuilder row: @escaping (Item) -> some View) -> some View {
        if items.isEmpty {
            none(empty)
        } else {
            VStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    if index > 0 {
                        Divider().padding(.leading, 14)
                    }
                    row(items[index])
                }
            }
            .background(Color.card, in: .rect(cornerRadius: 12))
        }
    }

    private func row(_ symbol: some View, text: String, detail: String?, at time: TimeInterval) -> some View {
        MinutesRow(time: time, jump: jump) {
            symbol
                .foregroundStyle(.tertiary)
                .frame(width: 18 * scale)
                .accessibilityHidden(true)
        } content: {
            Text(meeting.named(text))
                .font(.scaled(.body, scale))
            if let detail, !detail.isEmpty {
                Text(meeting.named(detail))
                    .font(.scaled(.callout, scale))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func topic(_ topic: Minutes.Topic, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(number). \(meeting.named(topic.title))")
                    .font(.scaled(.title3, scale, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TimeButton(
                    label: "\(MeetingTime.format(topic.start))–\(MeetingTime.format(topic.end))",
                    action: { jump(topic.start) })
            }
            VStack(alignment: .leading, spacing: 4 * scale) {
                ForEach(topic.points.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
                        Text("•")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text(meeting.named(topic.points[index]))
                            .lineSpacing(2 * scale)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .font(.scaled(.body, scale))
                }
            }
        }
    }
}

/// One row on a card: a mark, the text, and its time at the end.
private struct MinutesRow<Mark: View, Content: View>: View {
    let time: TimeInterval
    let jump: (TimeInterval) -> Void
    @ViewBuilder let mark: Mark
    @ViewBuilder let content: Content
    @Environment(\.textScale) private var scale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10 * scale) {
            mark
            VStack(alignment: .leading, spacing: 3 * scale) {
                content
            }
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            TimeButton(label: MeetingTime.format(time), action: { jump(time) })
        }
        .padding(.vertical, 11 * scale)
        .padding(.horizontal, 14)
    }
}

/// A task with a checkbox, who it's for and by when.
struct ActionItemRow: View {
    let item: Minutes.ActionItem
    let meeting: Meeting
    let isDone: Bool
    let toggle: () -> Void
    let jump: (TimeInterval) -> Void
    @Environment(\.textScale) private var scale

    struct Owner: Equatable {
        var text: String
        /// False for "Pembicara 3" and when nobody was named: shown in italics.
        var isNamed: Bool
    }

    /// The speaker's name once they have one, else the name the AI heard,
    /// else "Pembicara N"; "Pemilik tidak disebut" when nobody was named.
    static func owner(of item: Minutes.ActionItem, in meeting: Meeting) -> Owner {
        let heard = item.owner?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let speaker = item.owner?.speaker {
            if meeting.hasName(speaker) { return Owner(text: meeting.displayName(for: speaker), isNamed: true) }
            if !heard.isEmpty { return Owner(text: heard, isNamed: true) }
            return Owner(text: meeting.displayName(for: speaker), isNamed: false)
        }
        if !heard.isEmpty { return Owner(text: heard, isNamed: true) }
        return Owner(text: "Pemilik tidak disebut", isNamed: false)
    }

    static func due(of item: Minutes.ActionItem) -> String {
        let due = item.due?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return due.isEmpty ? "tenggat tidak disebut" : due
    }

    var body: some View {
        MinutesRow(time: item.at, jump: jump) {
            Toggle(isOn: Binding { isDone } set: { _ in toggle() }) {
                Text(meeting.named(item.task))
            }
            .toggleStyle(Checkbox(scale: scale))
        } content: {
            Text(meeting.named(item.task))
                .font(.scaled(.body, scale))
                .strikethrough(isDone, color: .secondary)
                .foregroundStyle(isDone ? .secondary : .primary)
            subline
                .font(.scaled(.callout, scale))
                .foregroundStyle(.secondary)
        }
    }

    private var subline: Text {
        let owner = Self.owner(of: item, in: meeting)
        let name = owner.isNamed
            ? Text(owner.text).fontWeight(.semibold).foregroundStyle(isDone ? .secondary : .primary)
            : Text(owner.text).italic()
        return Text("\(name) · \(Self.due(of: item))")
    }
}

/// A checkbox that grows with the text size. Says the task and whether
/// it's done to VoiceOver.
private struct Checkbox: ToggleStyle {
    let scale: Double

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                .font(.scaled(.body, scale))
                .foregroundStyle(configuration.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 18 * scale)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(configuration.isOn ? "Tandai belum selesai" : "Tandai selesai")
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A meeting time in blue that opens the transcript there.
struct TimeButton: View {
    /// "05:12", or "00:02–00:24" for a topic.
    let label: String
    let action: () -> Void
    @Environment(\.textScale) private var scale

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.scaled(.callout, scale).monospacedDigit())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .pointerStyle(.link)
        .fixedSize()
        .help("Buka di transkrip")
        .accessibilityLabel("Buka transkrip pada \(label)")
    }
}

/// Who took part: the owner first, then the remote speakers, then
/// "Lainnya" for meeting audio no one was told apart in. Speakers without
/// a name are dashed and italic.
struct ParticipantChips: View {
    let meeting: Meeting
    let lines: [TranscriptLine]
    @Environment(\.textScale) private var scale

    /// Everyone with a line, after merges.
    static func participants(of meeting: Meeting, lines: [TranscriptLine]) -> [SpeakerID] {
        Set(lines.map { meeting.speaker(of: $0) }).sorted { rank($0) < rank($1) }
    }

    private static func rank(_ id: SpeakerID) -> (Int, Int) {
        if id == .me { return (0, 0) }
        if let number = id.remoteNumber { return (1, number) }
        return (2, 0)
    }

    var body: some View {
        let people = Self.participants(of: meeting, lines: lines)
        if !people.isEmpty {
            FlowLayout(spacing: 6 * scale) {
                ForEach(people, id: \.self) { chip($0) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Peserta: \(people.map { meeting.displayName(for: $0) }.joined(separator: ", "))")
        }
    }

    @ViewBuilder
    private func chip(_ id: SpeakerID) -> some View {
        let name = meeting.displayName(for: id)
        if id == .me {
            Text(name)
                .font(.scaled(.callout, scale, weight: .semibold))
                .foregroundStyle(.tint)
                .chipPadding(scale)
                .background(.tint.opacity(0.12), in: .capsule)
        } else if meeting.hasName(id) {
            Text(name)
                .font(.scaled(.callout, scale))
                .chipPadding(scale)
                .background(Color.card, in: .capsule)
                .overlay { Capsule().strokeBorder(.separator, lineWidth: 0.5) }
        } else {
            Text(name)
                .italic()
                .font(.scaled(.callout, scale))
                .foregroundStyle(.secondary)
                .chipPadding(scale)
                .overlay { Capsule().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
        }
    }
}

private extension View {
    func chipPadding(_ scale: Double) -> some View {
        padding(.horizontal, 10 * scale).padding(.vertical, 3 * scale)
    }
}
