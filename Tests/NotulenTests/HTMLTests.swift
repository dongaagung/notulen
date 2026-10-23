import Foundation
import Testing
@testable import Notulen

private let zone = TimeZone(identifier: "Asia/Jakarta")!
// Kamis, 22 Oktober 2026 09.00 WIB
private let start = Date(timeIntervalSince1970: 1_792_634_400)

private func meeting(title: String = "Weekly Sync Tim Produk", done: Set<String> = []) -> Meeting {
    Meeting(
        title: title, startedAt: start, endedAt: start.addingTimeInterval(4320),
        status: .ready, language: "id-ID", audioSource: .systemWide,
        speakers: [SpeakerInfo(id: .remote(1), name: "Andi"), SpeakerInfo(id: .remote(2), name: nil)],
        actionItemsDone: done)
}

private let minutes = Minutes(
    titleSuggestion: "Saran", summary: "[[s1]] melapor kepada [[me]].",
    decisions: [Minutes.Decision(id: "d1", text: "Rilis diundur.", at: 14)],
    actionItems: [
        Minutes.ActionItem(id: "a1", task: "Tugas a1", owner: .init(speaker: .remote(1), name: nil), due: "Jumat", at: 16),
        Minutes.ActionItem(id: "a2", task: "Tugas a2", owner: nil, due: nil, at: 66),
    ],
    openQuestions: [Minutes.OpenQuestion(id: "q1", question: "Anggaran?", context: "Kata [[s1]], pemakaian naik.", at: 52)],
    topics: [Minutes.Topic(title: "Status", start: 2, end: 24, points: ["Fitur selesai.", "[[s2]] menguji."])])

private func render(_ minutes: Minutes = minutes, _ meeting: Meeting = meeting()) -> String {
    MinutesHTML.render(minutes, meeting: meeting, timeZone: zone)
}

/// True when every needle appears, each after the one before.
private func appearsInOrder(_ needles: [String], in text: String) -> Bool {
    var rest = text[...]
    for needle in needles {
        guard let range = rest.range(of: needle) else { return false }
        rest = rest[range.upperBound...]
    }
    return true
}

struct HTMLTests {
    @Test func htmlEscapesText() {
        var hostile = minutes
        hostile.summary = "<script>alert(1)</script>"
        hostile.decisions = [Minutes.Decision(id: "d1", text: "A & B \"kutip\" 'satu'", at: 14)]
        let out = render(hostile, meeting(title: "Rapat <b>"))
        #expect(out.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!out.contains("<script>"))
        #expect(out.contains("A &amp; B &quot;kutip&quot; &#39;satu&#39;"))
        #expect(out.contains("<title>Rapat &lt;b&gt;</title>"))
        #expect(!out.contains("Rapat <b>"))
    }

    @Test func htmlHasAllSections() {
        let headings = ["Ringkasan", "Keputusan", "Action item", "Pertanyaan terbuka", "Topik yang dibahas"]
        #expect(appearsInOrder(headings.map { "<h2>\($0)</h2>" }, in: render()))
    }

    @Test func contentMatchesTheMarkdownOrder() {
        let out = render(minutes, meeting(done: ["a2"]))
        #expect(appearsInOrder([
            "Kamis, 22 Oktober 2026 · 09.00–10.12 · 1 jam 12 menit · Bahasa Indonesia",
            "<h1>Weekly Sync Tim Produk</h1>",
            "Peserta: Saya, Andi, Pembicara 2",
            "Andi melapor kepada Saya.",
            "Rilis diundur.", "00:14",
            "Tugas a1", "Andi", "Jumat", "00:16",
            "Tugas a2", "pemegang tidak disebut", "01:06",
            "Anggaran?", "Kata Andi, pemakaian naik.", "00:52",
            "1. Status", "00:02–00:24", "Fitur selesai.", "Pembicara 2 menguji.",
        ], in: out))
    }

    @Test func checkboxesShowWhatIsDone() {
        let out = render(minutes, meeting(done: ["a1"]))
        #expect(out.contains("☑</span><div class=\"text\"><span class=\"task\">Tugas a1"))
        #expect(out.contains("☐</span><div class=\"text\"><span class=\"task\">Tugas a2"))
    }

    @Test func unnamedOwnersLookUnnamed() {
        var owners = minutes
        owners.actionItems.append(
            Minutes.ActionItem(id: "a3", task: "Tugas a3", owner: .init(speaker: .remote(2), name: nil), due: nil, at: 70))
        let out = render(owners)
        #expect(out.contains("<span class=\"owner\">Andi</span> · Jumat"))
        #expect(out.contains("<span class=\"owner anon\">pemegang tidak disebut</span>"))
        #expect(out.contains("<span class=\"owner anon\">Pembicara 2</span>"))
    }

    @Test func questionContextShowsUnderTheQuestion() {
        #expect(render().contains("Anggaran?<span class=\"sub\">Kata Andi, pemakaian naik.</span></div>"))
        var odd = minutes
        odd.openQuestions[0].context = "<b>\n[[s2]]"
        #expect(render(odd).contains("Anggaran?<span class=\"sub\">&lt;b&gt; Pembicara 2</span></div>"))
        for context in [nil, " \n "] as [String?] {
            var bare = minutes
            bare.openQuestions[0].context = context
            #expect(render(bare).contains("Anggaran?</div>"))
        }
    }

    @Test func timesPastAnHourUseHours() {
        var late = minutes
        late.decisions = [Minutes.Decision(id: "d", text: "Ok", at: 4514)]
        late.topics = [Minutes.Topic(title: "Akhir", start: 3600, end: 4514, points: [])]
        let out = render(late)
        #expect(out.contains(">1:15:14<"))
        #expect(out.contains(">1:00:00–1:15:14<"))
    }

    @Test func emptySectionsSayNone() {
        let out = render(Minutes(titleSuggestion: "", summary: ""), meeting(title: " "))
        #expect(out.components(separatedBy: "<p class=\"none\">Tidak ada.</p>").count == 6)
        #expect(out.contains("<h1>Tanpa judul</h1>"))
    }

    @Test func summaryKeepsItsLineBreaks() {
        var long = minutes
        long.summary = "Paragraf satu.\n\nParagraf dua."
        #expect(render(long).contains("<p class=\"summary\">Paragraf satu.\n\nParagraf dua.</p>"))
    }

    @Test func pageIsA4WithSystemFont() {
        let out = render()
        #expect(out.contains("@page { size: A4; margin: 18mm; }"))
        #expect(out.contains("font-family: -apple-system"))
        #expect(out.hasPrefix("<!DOCTYPE html>"))
    }

    @Test func pdfFileNameHasTitleAndDate() {
        #expect(PDFExporter.fileName(title: "Weekly Sync", date: start, timeZone: zone) == "Weekly Sync – 2026-10-22.pdf")
        #expect(PDFExporter.fileName(title: "Q1/Q2: Rencana", date: start, timeZone: zone)
            == "Q1-Q2- Rencana – 2026-10-22.pdf")
    }
}
