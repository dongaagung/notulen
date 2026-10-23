import Foundation
import Testing
@testable import Notulen

struct TranscriptRowsTests {
    private func line(_ start: TimeInterval, _ text: String? = nil) -> TranscriptLine {
        TranscriptLine(
            channel: .meeting, speaker: .others, text: text ?? "Baris \(Int(start))", start: start, end: start + 2)
    }

    /// A line's text, or a divider's.
    private func shown(_ rows: [TranscriptRows.Row]) -> [String] {
        rows.map { row in
            switch row {
            case .line(let line): line.text
            case .gap, .micOff: row.dividerText ?? ""
            }
        }
    }

    /// Spec §12: the transcript shows where the recording broke off, and
    /// where the owner's mic was off, between the lines in time order.
    @Test func dividersGoBetweenTheLinesInTimeOrder() {
        let rows = TranscriptRows.build(
            lines: [line(0), line(100), line(3_600)],
            gaps: [Gap(span: TimeSpan(start: 2_530, end: 3_510), reason: .sleep)],
            micOff: [TimeSpan(start: 720, end: 930)])
        #expect(shown(rows) == [
            "Baris 0", "Baris 100",
            "Mic mati 12:00–15:30",
            "Rekaman terputus 42:10–58:30 (Mac tidur)",
            "Baris 3600",
        ])
        #expect(rows.map(\.time) == [0, 100, 720, 2_530, 3_600])
    }

    @Test func gapsSayWhyTheRecordingBrokeOff() {
        let gaps = [
            Gap(span: TimeSpan(start: 60, end: 200), reason: .crash),
            Gap(span: TimeSpan(start: 3_600, end: 4_514), reason: .deviceLost),
            Gap(span: TimeSpan(start: 10, end: 20), reason: .sleep),
        ]
        #expect(shown(TranscriptRows.build(lines: [], gaps: gaps, micOff: [])) == [
            "Rekaman terputus 00:10–00:20 (Mac tidur)",
            "Rekaman terputus 01:00–03:20 (app berhenti)",
            "Rekaman terputus 1:00:00–1:15:14 (perangkat audio hilang)",
        ])
    }

    /// The journal can be slightly out of order; a divider comes before a
    /// line that starts when it does.
    @Test func linesAreInTimeOrderAndDividersComeFirstOnATie() {
        let rows = TranscriptRows.build(
            lines: [line(50, "b"), line(10, "a"), line(200, "c")],
            gaps: [Gap(span: TimeSpan(start: 50, end: 180), reason: .sleep)], micOff: [])
        #expect(shown(rows) == ["a", "Rekaman terputus 00:50–03:00 (Mac tidur)", "b", "c"])
    }

    @Test func withoutPausesOnlyTheLinesShow() {
        let lines = [line(0), line(5)]
        #expect(TranscriptRows.build(lines: lines, gaps: [], micOff: []) == lines.map { .line($0) })
        #expect(TranscriptRows.summary(gaps: [], micOff: []) == nil)
    }

    /// Every row has its own ID, also two pauses at the same time.
    @Test func rowIDsAreUnique() {
        let span = TimeSpan(start: 30, end: 40)
        let rows = TranscriptRows.build(
            lines: [line(0), line(30)],
            gaps: [Gap(span: span, reason: .sleep), Gap(span: span, reason: .sleep)], micOff: [span, span])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    /// The minutes list the pauses on one line under the meta line.
    @Test func summaryListsThePausesInTimeOrder() {
        let summary = TranscriptRows.summary(
            gaps: [Gap(span: TimeSpan(start: 2_530, end: 3_510), reason: .sleep)],
            micOff: [TimeSpan(start: 720, end: 930)])
        #expect(summary == "Mic mati 12:00–15:30 · Rekaman terputus 42:10–58:30 (Mac tidur)")
    }
}
