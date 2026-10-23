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
    openQuestions: [Minutes.OpenQuestion(id: "q1", question: "Anggaran?", context: "Kata [[s1]], pemakaian naik.", at: 52)],
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

    @Test func questionContextFollowsOnItsOwnLine() {
        #expect(render().contains("\n- Anggaran? (00:52)\n  Kata Andi, pemakaian naik.\n\n## Topik"))
        for context in [nil, " \n "] as [String?] {
            var bare = minutes
            bare.openQuestions[0].context = context
            #expect(render(bare).contains("\n- Anggaran? (00:52)\n\n## Topik"))
        }
    }

    @Test func blankSummarySaysNone() {
        var blank = minutes
        blank.summary = " \n "
        #expect(render(blank).contains("## Ringkasan\n\n_Tidak ada._\n"))
    }

    @Test func timesPastAnHourUseHours() {
        var late = minutes
        late.decisions = [Minutes.Decision(id: "d", text: "Ok", at: 4514)]
        #expect(render(late).contains("- Ok (1:15:14)"))
    }

    @Test func participantsListMergedSpeakersOnce() {
        #expect(MinutesFormatting.participants(of: meeting()) == ["Saya", "Andi", "Pembicara 2"])
    }

    @Test func heardOwnerNameShowsSpeakerNames() {
        var heard = minutes
        heard.actionItems = [item("a1", owner: .init(speaker: nil, name: "[[s1]] dan\n[[s3]]"), due: nil)]
        #expect(MinutesFormatting.owner(heard.actionItems[0], in: meeting()) == "Andi dan Pembicara 2")
        #expect(render(heard).contains("- [ ] Tugas a1 — Andi dan Pembicara 2 (01:00)"))
    }

    @Test func titleFallsBackPastBlankTitles() {
        var blankTitle = meeting()
        blankTitle.title = " \n "
        var noSuggestion = minutes
        noSuggestion.titleSuggestion = "  "
        #expect(MinutesFormatting.title(minutes, meeting: blankTitle) == "Saran")
        #expect(MinutesFormatting.title(noSuggestion, meeting: blankTitle) == "Tanpa judul")
        #expect(render(noSuggestion, blankTitle).hasPrefix("# Tanpa judul\n"))
        var padded = meeting()
        padded.title = "  Rapat  "
        #expect(MinutesFormatting.title(minutes, meeting: padded) == "Rapat")
    }

    @Test func oneLineFieldsCollapseLineBreaks() {
        var broken = minutes
        broken.summary = "Baris satu.\nBaris dua."
        broken.decisions = [Minutes.Decision(id: "d1", text: "Rilis\n\n## diundur.", at: 14)]
        broken.actionItems = [
            Minutes.ActionItem(
                id: "a1", task: "Tugas\n- palsu", owner: .init(speaker: .remote(1), name: nil), due: "Jumat\n depan",
                at: 16),
        ]
        broken.openQuestions = [
            Minutes.OpenQuestion(id: "q1", question: "Anggaran?\r\nNaik?", context: "Pemakaian\n\n## naik.", at: 52),
        ]
        broken.topics = [Minutes.Topic(title: "Status\nrilis", start: 2, end: 24, points: ["Fitur\n  selesai."])]
        let out = render(broken)
        #expect(out.contains("\nBaris satu.\nBaris dua.\n"))
        #expect(out.contains("\n- Rilis ## diundur. (00:14)\n"))
        #expect(out.contains("\n- [ ] Tugas - palsu — Andi · Jumat depan (00:16)\n"))
        #expect(out.contains("\n- Anggaran? Naik? (00:52)\n  Pemakaian ## naik.\n"))
        #expect(out.contains("\n### 1. Status rilis (00:02–00:24)\n"))
        #expect(out.contains("\n- Fitur selesai.\n"))
    }
}
