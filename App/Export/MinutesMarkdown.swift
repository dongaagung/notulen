import Foundation

/// The minutes as Markdown that pastes into Notion: headings, bullets and
/// "- [ ]" / "- [x]" checkboxes.
enum MinutesMarkdown {
    static let none = "_Tidak ada._"

    static func render(_ minutes: Minutes, meeting: Meeting, timeZone: TimeZone = .current) -> String {
        func time(_ seconds: Double) -> String { MeetingTime.format(seconds) }
        func text(_ text: String) -> String { MinutesFormatting.oneLine(text, in: meeting) }
        func section(_ title: String, _ items: [String]) -> [String] {
            ["## \(title)", ""] + (items.isEmpty ? [none] : items) + [""]
        }
        var out = [
            "# \(MinutesFormatting.title(minutes, meeting: meeting))", "",
            MinutesFormatting.dateLine(meeting, timeZone: timeZone),
            "Peserta: " + MinutesFormatting.participants(of: meeting).joined(separator: ", "), "",
        ]
        out += ["## Ringkasan", "", MinutesFormatting.summary(minutes, in: meeting) ?? none, ""]
        out += section("Keputusan", minutes.decisions.map { "- \(text($0.text)) (\(time($0.at)))" })
        out += section("Action item", minutes.actionItems.map { item in
            let box = meeting.actionItemsDone.contains(item.id) ? "[x]" : "[ ]"
            let due = MinutesFormatting.due(item, in: meeting).map { " · \($0)" } ?? ""
            return "- \(box) \(text(item.task)) — \(MinutesFormatting.owner(item, in: meeting))\(due) (\(time(item.at)))"
        })
        out += section("Pertanyaan terbuka", minutes.openQuestions.map { "- \(text($0.question)) (\(time($0.at)))" })
        out += ["## Topik yang dibahas", ""]
        if minutes.topics.isEmpty { out += [none, ""] }
        for (index, topic) in minutes.topics.enumerated() {
            out += ["### \(index + 1). \(text(topic.title)) (\(time(topic.start))–\(time(topic.end)))", ""]
            out += topic.points.map { "- \(text($0))" }
            if !topic.points.isEmpty { out.append("") }
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }
}
