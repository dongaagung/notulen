import Foundation
import Testing
@testable import Notulen

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "id_ID")
    calendar.timeZone = TimeZone(identifier: "Asia/Jakarta")!
    calendar.firstWeekday = 2
    return calendar
}()

private func date(_ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
}

private func meeting(_ title: String, _ startedAt: Date) -> Meeting {
    Meeting(title: title, startedAt: startedAt, status: .ready, language: "id-ID", audioSource: .systemWide)
}

struct SidebarTests {
    @Test func groupsByTodayWeekAndMonth() {
        let now = date(10, 22, 10)  // Thursday
        let meetings = [
            meeting("a", date(10, 22)), meeting("b", date(10, 19)), meeting("c", date(10, 14)),
            meeting("d", date(9, 30)),
        ]
        let groups = MeetingGroups.group(meetings, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Hari ini", "Minggu ini", "Oktober 2026", "September 2026"])
        #expect(groups.map { $0.meetings.map(\.title) } == [["a"], ["b"], ["c"], ["d"]])
    }

    @Test func emptyGroupsAreOmittedAndMonthsStayNewestFirst() {
        let now = date(10, 22, 10)
        let meetings = [meeting("new", date(10, 3)), meeting("mid", date(8, 3)), meeting("old", date(8, 1))]
        let groups = MeetingGroups.group(meetings, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Oktober 2026", "Agustus 2026"])
        #expect(groups[1].meetings.map(\.title) == ["mid", "old"])
    }

    @Test func searchFindsTopicText() {
        var m = meeting("Rapat", date(10, 22))
        m.minutes = Minutes(
            titleSuggestion: "", summary: "",
            topics: [.init(title: "Migrasi database ke Postgres 17", start: 0, end: 1, points: [])])
        #expect(MeetingGroups.matches(m, query: "postgres"))
        #expect(!MeetingGroups.matches(m, query: "kafka"))
        #expect(MeetingGroups.matches(m, query: ""))
        #expect(MeetingGroups.matches(m, query: "  "))
    }

    @Test func searchCoversTitleSummaryDecisionsActionsAndLiveNotes() {
        var m = meeting("Café Sync", date(10, 22))
        m.minutes = Minutes(
            titleSuggestion: "", summary: "Ringkasan anggaran",
            decisions: [.init(id: "d1", text: "Pakai vendor Alfa", at: 0)],
            actionItems: [.init(id: "a1", task: "Kirim proposal", owner: nil, due: nil, at: 0)],
            topics: [.init(title: "T", start: 0, end: 1, points: ["poin rahasia"])])
        m.liveNotes = LiveNotes(
            currentTopic: nil, topics: [.init(title: "Sementara", points: [.init(text: "catatan kilat", kind: .point)])])
        for query in ["cafe", "ANGGARAN", "alfa", "proposal", "rahasia", "sementara", "kilat"] {
            #expect(MeetingGroups.matches(m, query: query), "\(query)")
        }
        #expect(!MeetingGroups.matches(m, query: "zebra"))
    }
}
