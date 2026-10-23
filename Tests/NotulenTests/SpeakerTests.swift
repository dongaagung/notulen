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

    /// A name typed for a speaker survives merging it into one without a
    /// name; a target with a name keeps its own.
    @Test func mergeCarriesTheNameToAnUnnamedTarget() {
        var m = meeting(speakers: [SpeakerInfo(id: .remote(1), name: nil), SpeakerInfo(id: .remote(2), name: "Rina")])
        m.merge(.remote(2), into: .remote(1))
        #expect(m.displayName(for: .remote(1)) == "Rina")
        #expect(m.displayName(for: .remote(2)) == "Rina")
        #expect(m.hasName(.remote(1)))

        var named = meeting(speakers: [SpeakerInfo(id: .remote(1), name: "Andi"), SpeakerInfo(id: .remote(2), name: "Rina")])
        named.merge(.remote(2), into: .remote(1))
        #expect(named.displayName(for: .remote(2)) == "Andi")

        // Into a speaker merged on: the name goes to the end of the chain.
        var chain = meeting(
            speakers: [SpeakerInfo(id: .remote(3), name: "Budi")], merges: [SpeakerMerge(from: .remote(2), to: .remote(1))])
        chain.merge(.remote(3), into: .remote(2))
        #expect(chain.displayName(for: .remote(1)) == "Budi")

        // No name, nothing to carry; a merge that would loop changes nothing.
        var unnamed = meeting(speakers: [SpeakerInfo(id: .remote(1), name: nil), SpeakerInfo(id: .remote(2), name: " ")])
        unnamed.merge(.remote(2), into: .remote(1))
        #expect(unnamed.displayName(for: .remote(1)) == "Pembicara 1")
        var loop = meeting(
            speakers: [SpeakerInfo(id: .remote(1), name: "Andi")], merges: [SpeakerMerge(from: .remote(2), to: .remote(1))])
        let before = loop
        loop.merge(.remote(1), into: .remote(2))
        #expect(loop == before)
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

    @Test func renameTrimsAndClears() {
        var m = meeting(speakers: [SpeakerInfo(id: .remote(1), name: nil)])
        m.rename(.remote(1), to: "  Andi ")
        #expect(m.displayName(for: .remote(1)) == "Andi")
        m.rename(.remote(1), to: "")
        #expect(m.displayName(for: .remote(1)) == "Pembicara 1")
        m.rename(.remote(1), to: "  \n ")
        #expect(m.speakers.first { $0.id == .remote(1) }?.name == nil)
    }

    @Test func renameAddsMissingSpeaker() {
        var m = meeting()
        m.rename(.remote(2), to: "Rina")
        #expect(m.displayName(for: .remote(2)) == "Rina")
        #expect(m.speakers.count == 1)
    }

    @Test func mergeFollowsChains() {
        var m = meeting(speakers: [1, 2, 3].map { SpeakerInfo(id: .remote($0), name: nil) })
        m.merge(.remote(3), into: .remote(2))
        m.merge(.remote(2), into: .remote(1))
        #expect(m.speaker(of: line(.remote(3), "x", start: 0)) == .remote(1))
    }

    @Test func mergeLoopIsIgnored() {
        var m = meeting()
        m.merge(.remote(1), into: .remote(2))
        m.merge(.remote(2), into: .remote(1))
        m.merge(.remote(1), into: .remote(1))
        #expect(m.merges == [SpeakerMerge(from: .remote(1), to: .remote(2))])
        m.merge(.remote(3), into: .remote(1))
        m.merge(.remote(2), into: .remote(3))
        #expect(m.merges.count == 2)
    }

    @Test func sampleLinesPickLongest() {
        let m = meeting(merges: [SpeakerMerge(from: .remote(2), to: .remote(1))])
        let lines = [
            line(.remote(1), "pendek", start: 1), line(.remote(1), "ini kalimat yang paling panjang sekali", start: 2),
            line(.remote(2), "sedang saja kalimatnya", start: 3), line(.remote(3), "lain", start: 4),
            line(.remote(1), "ok", start: 5),
        ]
        let picked = m.sampleLines(for: .remote(1), in: lines, count: 2)
        #expect(picked.map(\.start) == [2, 3])
        #expect(m.sampleLines(for: .remote(3), in: lines).count == 1)
    }

    @Test func mergeTargetsExcludeSelfAndLoops() {
        var m = meeting(speakers: [1, 2, 3].map { SpeakerInfo(id: .remote($0), name: nil) })
        m.merge(.remote(2), into: .remote(1))
        #expect(m.mergeTargets(for: .remote(1), among: [.remote(1), .remote(2), .remote(3)]) == [.remote(3)])
        #expect(m.mergeTargets(for: .remote(3), among: [.remote(1), .remote(3)]) == [.remote(1)])
    }
}
