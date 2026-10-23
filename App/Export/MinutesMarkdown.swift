import Foundation

/// The minutes as Markdown that pastes into Notion: headings, bullets and
/// "- [ ]" / "- [x]" checkboxes.
enum MinutesMarkdown {
    static let none = "_Tidak ada._"

    static func render(_ minutes: Minutes, meeting: Meeting, timeZone: TimeZone = .current) -> String {
        func time(_ seconds: Double) -> String { MeetingTime.format(seconds) }
        func section(_ title: String, _ items: [String]) -> [String] {
            ["## \(title)", ""] + (items.isEmpty ? [none] : items) + [""]
        }
        var out = [
            "# \(meeting.title.isEmpty ? minutes.titleSuggestion : meeting.title)", "",
            MinutesFormatting.dateLine(meeting, timeZone: timeZone),
            "Peserta: " + MinutesFormatting.participants(of: meeting).joined(separator: ", "), "",
        ]
        out += ["## Ringkasan", "", minutes.summary.isEmpty ? none : meeting.named(minutes.summary), ""]
        out += section("Keputusan", minutes.decisions.map { "- \(meeting.named($0.text)) (\(time($0.at)))" })
        out += section("Action item", minutes.actionItems.map { item in
            let box = meeting.actionItemsDone.contains(item.id) ? "[x]" : "[ ]"
            let due = item.due?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let who = MinutesFormatting.owner(item, in: meeting) + (due.isEmpty ? "" : " · \(meeting.named(due))")
            return "- \(box) \(meeting.named(item.task)) — \(who) (\(time(item.at)))"
        })
        out += section("Pertanyaan terbuka", minutes.openQuestions.map { "- \(meeting.named($0.question)) (\(time($0.at)))" })
        out += ["## Topik yang dibahas", ""]
        if minutes.topics.isEmpty { out += [none, ""] }
        for (index, topic) in minutes.topics.enumerated() {
            out += ["### \(index + 1). \(meeting.named(topic.title)) (\(time(topic.start))–\(time(topic.end)))", ""]
            out += topic.points.map { "- \(meeting.named($0))" }
            if !topic.points.isEmpty { out.append("") }
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }
}
