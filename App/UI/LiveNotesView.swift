import SwiftUI

/// The live notes: the topic being discussed now in large type with its
/// points, when the notes were last updated, and the other topics, each
/// folded to its summary. Before the first notes it says when they come,
/// or why they won't.
struct LiveNotesView: View {
    let notes: LiveNotes?
    let updatedAt: Date?
    /// Why no notes are coming, such as a missing API key.
    let problem: String?
    @Environment(\.textScale) private var scale
    /// The other topics the owner opened, by title: the model may merge or
    /// reorder topics between updates, which moves their indices.
    @ViewState private var expanded: Set<String> = []

    static let placeholder = "Catatan pertama muncul sekitar 2–3 menit setelah percakapan dimulai."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let notes, let layout = Layout(notes) {
                currentTopic(notes.topics[layout.current])
                status
                if !layout.previous.isEmpty {
                    otherTopics(notes, layout.previous)
                }
            } else {
                placeholderView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Which topic is shown as being discussed, and which are folded below.
    struct Layout: Equatable {
        var current: Int
        /// In meeting order.
        var previous: [Int]

        /// The model's current topic, else the newest one. Nil without topics.
        init?(_ notes: LiveNotes) {
            guard !notes.topics.isEmpty else { return nil }
            let named = notes.currentTopic.flatMap { notes.topics.indices.contains($0) ? $0 : nil }
            let current = named ?? notes.topics.count - 1
            self.current = current
            previous = notes.topics.indices.filter { $0 != current }
        }
    }

    /// The label after a point of this kind; a plain point has none.
    static func tag(for kind: LiveNotes.Kind) -> String? {
        switch kind {
        case .point: nil
        case .decision: "keputusan"
        case .actionItem: "action item"
        case .openQuestion: "pertanyaan"
        }
    }

    /// "Diperbarui 2 menit yang lalu"; under a minute, "Diperbarui baru saja".
    static func updatedLabel(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "Diperbarui baru saja" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "id_ID")
        formatter.unitsStyle = .full
        return "Diperbarui \(formatter.localizedString(for: date, relativeTo: now))"
    }

    // MARK: Sections

    private func currentTopic(_ topic: LiveNotes.Topic) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(.tint)
                    .frame(width: 7, height: 7)
                    .background { Circle().fill(.tint.opacity(0.18)).frame(width: 15, height: 15) }
                    .accessibilityHidden(true)
                Text("Sedang dibahas")
            }
            .font(.scaled(.callout, scale, weight: .semibold))
            .foregroundStyle(.tint)
            .padding(.bottom, 6 * scale)
            Text(topic.title)
                .font(.scaled(.largeTitle, scale, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.bottom, 14 * scale)
            PointList(points: topic.points)
        }
    }

    @ViewBuilder
    private var status: some View {
        if updatedAt != nil || problem != nil {
            VStack(alignment: .leading, spacing: 6 * scale) {
                if let updatedAt {
                    // Minutes are all it shows.
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text(Self.updatedLabel(updatedAt, now: context.date))
                    }
                    .foregroundStyle(.tertiary)
                }
                // The notes stop updating; say why.
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.scaled(.subheadline, scale))
            .padding(.top, 12 * scale)
        }
    }

    private func otherTopics(_ notes: LiveNotes, _ indices: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            Text("Topik sebelumnya")
                .font(.scaled(.callout, scale, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(spacing: 0) {
                ForEach(indices, id: \.self) { index in
                    if index != indices.first {
                        Divider().padding(.leading, 14)
                    }
                    let topic = notes.topics[index]
                    topicRow(topic, number: index + 1, isExpanded: isExpanded(topic.title))
                }
            }
            .background(Color.card, in: .rect(cornerRadius: 12))
        }
        .padding(.top, 30 * scale)
    }

    private func topicRow(_ topic: LiveNotes.Topic, number: Int, isExpanded: Binding<Bool>) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            // Under the title, past the number.
            PointList(points: topic.points)
                .padding(.top, 10 * scale)
                .padding(.leading, 20 * scale + 10)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(number))
                    .font(.scaled(.subheadline, scale, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20 * scale, minHeight: 20 * scale)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 6))
                    .accessibilityHidden(true)
                Text(topic.title)
                    .font(.scaled(.body, scale, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .lineLimit(isExpanded.wrappedValue ? nil : 1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(topic.summary)
                    .font(.scaled(.callout, scale))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .disclosureGroupStyle(TopicDisclosureStyle())
        // The chevron's size.
        .font(.scaled(.callout, scale, weight: .semibold))
        .padding(.vertical, 11 * scale)
        .padding(.horizontal, 14)
    }

    private func isExpanded(_ title: String) -> Binding<Bool> {
        Binding {
            expanded.contains(title)
        } set: { open in
            if open { expanded.insert(title) } else { expanded.remove(title) }
        }
    }

    private var placeholderView: some View {
        Group {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
            } else {
                Text(Self.placeholder)
            }
        }
        .font(.scaled(.title3, scale))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The whole row opens and closes the topic, with a chevron at its end.
private struct TopicDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { configuration.isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    configuration.label
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Terbuka" : "Tertutup")
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

/// A topic's points as a bulleted list. Decisions, action items and open
/// questions carry a label; open questions read quieter.
private struct PointList: View {
    let points: [LiveNotes.Point]
    @Environment(\.textScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 7 * scale) {
            ForEach(points.indices, id: \.self) { index in
                row(points[index])
            }
        }
    }

    private func row(_ point: LiveNotes.Point) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
            Text("•")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(point.text)
                .foregroundStyle(point.kind == .openQuestion ? HierarchicalShapeStyle.secondary : .primary)
                .lineSpacing(2 * scale)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let tag = LiveNotesView.tag(for: point.kind) {
                Text(tag)
                    .font(.scaled(.caption, scale, weight: .semibold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 7 * scale)
                    .padding(.vertical, 1.5 * scale)
                    .background(.tint.opacity(0.12), in: .capsule)
                    .fixedSize()
            }
        }
        .font(.scaled(.body, scale))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
