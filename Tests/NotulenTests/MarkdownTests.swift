import Foundation
import Testing
@testable import Notulen

private let zone = TimeZone(identifier: "Asia/Jakarta")!
// Kamis, 22 Oktober 2026 09.00 WIB
private let start = Date(timeIntervalSince1970: 1_792_634_400)

private func meeting(done: Set<String> = []) -> Meeting {
    Meeting(
        title: "Weekly Sync Tim Produk", startedAt: start, endedAt: start.addingTimeInterval(4320),
        status: .ready, language: "id-ID", audioSource: .systemWide,
        speakers: [
            SpeakerInfo(id: .remote(1), name: "Andi"), SpeakerInfo(id: .remote(2), name: nil),
            SpeakerInfo(id: .remote(3), name: nil),
        ],
        merges: [SpeakerMerge(from: .remote(3), to: .remote(2))], actionItemsDone: done)
}

private func item(_ id: String, owner: Minutes.ActionItem.Owner?, due: String?, at: Double = 60) -> Minutes.ActionItem {
    Minutes.ActionItem(id: id, task: "Tugas \(id)", owner: owner, due: due, at: at)
}

private let minutes = Minutes(
    titleSuggestion: "Saran", summary: "[[s1]] melapor kepada [[me]].",
    decisions: [Minutes.Decision(id: "d1", text: "Rilis diundur.", at: 14)],
    actionItems: [
        item("a1", owner: .init(speaker: .remote(1), name: nil), due: "Jumat", at: 16),
        item("a2", owner: nil, due: nil, at: 66),
    ],
    openQuestions: [Minutes.OpenQuestion(id: "q1", question: "Anggaran?", context: nil, at: 52)],
    topics: [Minutes.Topic(title: "Status", start: 2, end: 24, points: ["Fitur selesai.", "[[s2]] menguji."])])

private func render(_ minutes: Minutes = minutes, _ meeting: Meeting = meeting()) -> String {
    MinutesMarkdown.render(minutes, meeting: meeting, timeZone: zone)
}

struct MarkdownTests {
    @Test func rendersFixtureExactly() throws {
        let url = try #require(Bundle.module.url(forResource: "minutes", withExtension: "md", subdirectory: "Fixtures"))
        #expect(render(minutes, meeting(done: ["a2"])) == (try String(contentsOf: url, encoding: .utf8)))
    }

    @Test func dateLineIsIndonesian() {
        #expect(MinutesFormatting.dateLine(meeting(), timeZone: zone)
            == "Kamis, 22 Oktober 2026 · 09.00–10.12 · 1 jam 12 menit · Bahasa Indonesia")
        #expect(MinutesFormatting.duration(2700) == "45 menit")
    }

    @Test func checkedActionItemUsesX() {
        let out = render(minutes, meeting(done: ["a1"]))
        #expect(out.contains("- [x] Tugas a1 — Andi · Jumat (00:16)"))
        #expect(out.contains("- [ ] Tugas a2"))
    }

    @Test func missingOwnerSaysNotMentioned() {
        #expect(render().contains("- [ ] Tugas a2 — pemegang tidak disebut (01:06)"))
    }

    @Test func emptySectionSaysNone() {
        var empty = minutes
        empty.openQuestions = []
        #expect(render(empty).contains("## Pertanyaan terbuka\n\n_Tidak ada._\n"))
    }

    @Test func timesPastAnHourUseHours() {
        var late = minutes
        late.decisions = [Minutes.Decision(id: "d", text: "Ok", at: 4514)]
        #expect(render(late).contains("- Ok (1:15:14)"))
    }

    @Test func participantsListMergedSpeakersOnce() {
        #expect(MinutesFormatting.participants(of: meeting()) == ["Saya", "Andi", "Pembicara 2"])
    }
}
