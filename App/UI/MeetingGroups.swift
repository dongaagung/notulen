import Foundation

/// Sidebar grouping by date, and the sidebar search.
enum MeetingGroups {
    /// "Hari ini", "Minggu ini" (the calendar week of `now`), then one group
    /// per month, newest first. Empty groups are left out.
    static func group(
        _ meetings: [Meeting], now: Date, calendar: Calendar
    ) -> [(title: String, meetings: [Meeting])] {
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "id_ID")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "LLLL yyyy"

        var groups: [(title: String, meetings: [Meeting])] = []
        func add(_ meeting: Meeting, to title: String) {
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].meetings.append(meeting)
            } else {
                groups.append((title, [meeting]))
            }
        }
        for meeting in meetings.sorted(by: { $0.startedAt > $1.startedAt }) {
            if calendar.isDate(meeting.startedAt, inSameDayAs: now) {
                add(meeting, to: "Hari ini")
            } else if let week, week.contains(meeting.startedAt) {
                add(meeting, to: "Minggu ini")
            } else {
                add(meeting, to: formatter.string(from: meeting.startedAt))
            }
        }
        return groups
    }

    /// Looks in the title, minutes and live notes, ignoring case and accents.
    /// A blank query matches everything.
    static func matches(_ meeting: Meeting, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return true }
        return searchableText(meeting).contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private static func searchableText(_ meeting: Meeting) -> [String] {
        var texts = [meeting.title]
        if let minutes = meeting.minutes {
            texts.append(minutes.summary)
            texts += minutes.decisions.map(\.text)
            texts += minutes.actionItems.map(\.task)
            for topic in minutes.topics {
                texts.append(topic.title)
                texts += topic.points
            }
        }
        for topic in meeting.liveNotes?.topics ?? [] {
            texts.append(topic.title)
            texts += topic.points.map(\.text)
        }
        return texts
    }
}
