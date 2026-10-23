import Foundation
import Testing
@testable import Notulen

private func meeting(
    speakers: [SpeakerInfo] = [], assignments: [SpeakerAssignment] = [], merges: [SpeakerMerge] = [],
    gaps: [Gap] = [], micOff: [TimeSpan] = [], endedAt: Date? = nil
) -> Meeting {
    Meeting(
        title: "T", startedAt: Date(timeIntervalSince1970: 1000), endedAt: endedAt, status: .ready,
        language: "id-ID", audioSource: .systemWide, gaps: gaps, micOff: micOff, speakers: speakers,
        speakerAssignments: assignments, merges: merges)
}

private func line(_ speaker: SpeakerID, _ text: String, start: TimeInterval) -> TranscriptLine {
    TranscriptLine(channel: .meeting, speaker: speaker, text: text, start: start, end: start + 2)
}

struct SpeakerTests {
    @Test func tokensRenderCurrentNames() {
        let m = meeting(speakers: [SpeakerInfo(id: .remote(3), name: "Andi")])
        #expect(SpeakerTokens.render("[[s3]] setuju dengan [[me]].", name: m.displayName(for:)) == "Andi setuju dengan Saya.")
    }

    @Test func unknownTokenRendersAsOthers() {
        let m = meeting()
        #expect(SpeakerTokens.render("[[s9]] bertanya", name: m.displayName(for:)) == "Lainnya bertanya")
    }

    @Test func unnamedRemoteSpeakerIsNumbered() {
        let m = meeting(speakers: [SpeakerInfo(id: .remote(2), name: nil)])
        #expect(m.displayName(for: .remote(2)) == "Pembicara 2")
        #expect(m.displayName(for: .others) == "Lainnya")
    }

    @Test func mergedSpeakerUsesTarget() {
        let l = line(.remote(1), "x", start: 0)
        let m = meeting(
            speakers: [SpeakerInfo(id: .remote(2), name: "Rina")],
            assignments: [SpeakerAssignment(line: l.id, speaker: .remote(4))],
            merges: [SpeakerMerge(from: .remote(4), to: .remote(2))])
        #expect(m.displayName(for: .remote(4)) == "Rina")
        #expect(m.speaker(of: l) == .remote(2))
    }

    @Test func mergeCycleTerminates() {
        let m = meeting(merges: [
            SpeakerMerge(from: .remote(1), to: .remote(2)), SpeakerMerge(from: .remote(2), to: .remote(1)),
        ])
        _ = m.speaker(of: line(.remote(1), "x", start: 0))
        _ = m.displayName(for: .remote(1))
    }

    @Test func aiTranscriptUsesHoursPastAnHour() {
        let l = line(.remote(1), "Oke", start: 4514)
        let m = meeting(speakers: [SpeakerInfo(id: .remote(1), name: nil)])
        let out = TranscriptFormatter.aiTranscript(lines: [l], meeting: m)
        #expect(out.contains("[1:15:14] [[s1]]: Oke"))
        #expect(out.contains("Bahasa meeting: id-ID"))
        #expect(!out.contains("Jeda rekaman"))
        #expect(!out.contains("Mic pemilik mati"))
    }

    @Test func aiTranscriptListsGapsAndMicOff() {
        let m = meeting(
            gaps: [Gap(span: TimeSpan(start: 2530, end: 3510), reason: .sleep)],
            micOff: [TimeSpan(start: 720, end: 930)])
        let out = TranscriptFormatter.aiTranscript(lines: [], meeting: m)
        #expect(out.contains("Jeda rekaman: 42:10–58:30 (Mac tidur)"))
        #expect(out.contains("Mic pemilik mati: 12:00–15:30"))
    }

    @Test func aiTranscriptDurationFromEndedAt() {
        let m = meeting(endedAt: Date(timeIntervalSince1970: 1000 + 4514))
        #expect(TranscriptFormatter.aiTranscript(lines: [], meeting: m).contains("Durasi: 1:15:14"))
    }

    @Test func aiTranscriptSortsLinesByStart() {
        let late = line(.remote(1), "Kedua", start: 20)
        let early = line(.remote(1), "Pertama", start: 5)
        let out = TranscriptFormatter.aiTranscript(lines: [late, early], meeting: meeting())
        #expect(out.range(of: "Pertama")!.lowerBound < out.range(of: "Kedua")!.lowerBound)
    }
}
