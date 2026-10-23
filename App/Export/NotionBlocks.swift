import Foundation

/// The minutes as Notion blocks, in the order of the Markdown export. The
/// page's title is the minutes' title, so the blocks start at the date.
enum NotionBlocks {
    static let maxTextLength = 2000
    /// Notion takes at most 100 elements in an array, rich text included.
    static let maxElements = 100
    private static let none = "Tidak ada."

    static func blocks(for minutes: Minutes, meeting: Meeting, timeZone: TimeZone = .current) -> [JSONValue] {
        func time(_ seconds: Double) -> String { MeetingTime.format(seconds) }
        func text(_ text: String) -> String { MinutesFormatting.oneLine(text, in: meeting) }
        func section(_ title: String, _ items: [[JSONValue]]) -> [JSONValue] {
            [heading(title)] + (items.isEmpty ? [paragraph(none)] : items.flatMap { $0 })
        }
        var out = [
            paragraph(MinutesFormatting.dateLine(meeting, timeZone: timeZone)),
            paragraph("Peserta: " + MinutesFormatting.participants(of: meeting).joined(separator: ", ")),
            heading("Ringkasan"),
        ]
        out += textBlocks("paragraph", MinutesFormatting.summary(minutes, in: meeting) ?? none)
        out += section("Keputusan", minutes.decisions.map {
            textBlocks("bulleted_list_item", "\(text($0.text)) (\(time($0.at)))")
        })
        out += section("Action item", minutes.actionItems.map { item in
            let due = MinutesFormatting.due(item, in: meeting).map { " · \($0)" } ?? ""
            let task = "\(text(item.task)) — \(MinutesFormatting.owner(item, in: meeting))\(due) (\(time(item.at)))"
            return textBlocks("to_do", task, extra: ["checked": .bool(meeting.actionItemsDone.contains(item.id))])
        })
        // The context continues the item on a line of its own, as in the Markdown.
        out += section("Pertanyaan terbuka", minutes.openQuestions.map { question in
            let context = MinutesFormatting.context(question, in: meeting).map { "\n\($0)" } ?? ""
            return textBlocks("bulleted_list_item", "\(text(question.question)) (\(time(question.at)))\(context)")
        })
        out.append(heading("Topik yang dibahas"))
        if minutes.topics.isEmpty { out.append(paragraph(none)) }
        for (index, topic) in minutes.topics.enumerated() {
            out += textBlocks("heading_3", "\(index + 1). \(text(topic.title)) (\(time(topic.start))–\(time(topic.end)))")
            out += topic.points.flatMap { textBlocks("bulleted_list_item", text($0)) }
        }
        return out
    }

    static func heading(_ text: String) -> JSONValue { textBlocks("heading_2", text)[0] }

    static func paragraph(_ text: String) -> JSONValue { textBlocks("paragraph", text)[0] }

    /// `text` as text objects of at most 2000 characters (Notion counts
    /// UTF-16 units), at most 100 of them: what fits one block. Longer text
    /// goes through `textBlocks`, which continues it in more blocks.
    static func richText(_ text: String) -> JSONValue {
        .array(richTextGroups(text).first ?? [])
    }

    /// A block of `type` holding `text`. Text too long for one block's rich
    /// text continues in plain paragraphs after it. `extra` goes next to
    /// `rich_text` (a to-do's `checked`).
    private static func textBlocks(_ type: String, _ text: String, extra: [String: JSONValue] = [:]) -> [JSONValue] {
        let groups = richTextGroups(text)
        return (groups.isEmpty ? [[]] : groups).enumerated().map { index, group in
            let kind = index == 0 ? type : "paragraph"
            var inner: [String: JSONValue] = ["rich_text": .array(group)]
            if index == 0 { inner.merge(extra) { _, new in new } }
            return .object(["object": "block", "type": .string(kind), kind: .object(inner)])
        }
    }

    private static func richTextGroups(_ text: String) -> [[JSONValue]] {
        var parts: [JSONValue] = []
        var current = ""
        var length = 0
        func flush() {
            guard !current.isEmpty else { return }
            parts.append(.object(["type": "text", "text": .object(["content": .string(current)])]))
            current = ""
            length = 0
        }
        for character in text {
            let units = character.utf16.count
            if length + units > maxTextLength { flush() }
            current.append(character)
            length += units
        }
        flush()
        return stride(from: 0, to: parts.count, by: maxElements).map {
            Array(parts[$0..<min($0 + maxElements, parts.count)])
        }
    }
}
