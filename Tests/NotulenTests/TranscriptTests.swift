import Foundation
import Testing
@testable import Notulen

struct TranscriptTests {
    @Test func volatileThenFinal() {
        var transcript = Transcript()
        #expect(transcript.apply(.init(text: "Halo", isFinal: false, span: nil), channel: .meeting, offset: 0, now: 1) == nil)
        #expect(transcript.volatileText[.meeting] == "Halo")
        let line = transcript.apply(.init(text: " Halo semuanya. ", isFinal: true, span: nil), channel: .meeting, offset: 0, now: 2)
        #expect(line?.text == "Halo semuanya.")
        #expect(transcript.volatileText[.meeting] == nil)
        #expect(transcript.lines.count == 1)
    }

    @Test func punctuationOnlyFinalJoinsPreviousLine() {
        var transcript = Transcript()
        transcript.apply(.init(text: "Apa kabar", isFinal: true, span: .init(start: 1, end: 2)), channel: .meeting, offset: 10, now: 12)
        #expect(transcript.apply(.init(text: "?", isFinal: true, span: .init(start: 2, end: 2.4)), channel: .meeting, offset: 10, now: 13) == nil)
        #expect(transcript.lines.map(\.text) == ["Apa kabar?"])
        #expect(transcript.lines[0].end == 12.4)
        transcript.apply(.init(text: "?", isFinal: true, span: nil), channel: .meeting, offset: 10, now: 14)
        #expect(transcript.lines.map(\.text) == ["Apa kabar?"])
    }

    @Test func emptyFinalAddsNoLine() {
        var transcript = Transcript()
        #expect(transcript.apply(.init(text: "  ", isFinal: true, span: nil), channel: .mic, offset: 0, now: 1) == nil)
        #expect(transcript.lines.isEmpty)
    }

    @Test func finalLineGetsMeetingTimesFromSpan() {
        var t = Transcript()
        let line = t.apply(.init(text: "Halo semua", isFinal: true, span: .init(start: 2, end: 3.5)), channel: .meeting, offset: 600, now: 604)
        #expect(line?.start == 602 && line?.end == 603.5 && line?.speaker == .others)
    }

    @Test func micLinesAreMine() {
        var t = Transcript()
        let line = t.apply(.init(text: "Saya setuju", isFinal: true, span: .init(start: 0, end: 1)), channel: .mic, offset: 0, now: 1)
        #expect(line?.channel == .mic && line?.speaker == .me)
    }

    @Test func missingSpanFallsBackToNow() {
        var t = Transcript()
        let line = t.apply(.init(text: "Baik", isFinal: true, span: nil), channel: .meeting, offset: 600, now: 50)
        #expect(line?.start == 50 && line?.end == 50)
    }
}

struct EchoFilterTests {
    private func others(_ text: String, at start: TimeInterval) -> TranscriptLine {
        TranscriptLine(channel: .meeting, speaker: .others, text: text, start: start, end: start + 2)
    }

    @Test func repeatOfOthersIsEcho() {
        let lines = [others("Tolong jelaskan rencana migrasi database minggu depan.", at: 100)]
        #expect(EchoFilter.isLikelyEcho("tolong jelaskan rencana migrasi database", at: 101, recent: lines))
    }

    @Test func realAnswerIsNotEcho() {
        let lines = [others("Tolong jelaskan rencana migrasi database minggu depan.", at: 100)]
        #expect(!EchoFilter.isLikelyEcho("Baik, kami mulai hari Senin dengan tim backend", at: 101, recent: lines))
    }

    @Test func oldLinesDontCount() {
        let lines = [others("Tolong jelaskan rencana migrasi database minggu depan.", at: 100)]
        #expect(!EchoFilter.isLikelyEcho("tolong jelaskan rencana migrasi database", at: 130, recent: lines))
    }
}
