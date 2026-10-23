import Foundation
import Testing
@testable import Notulen

private func topic(_ title: String) -> LiveNotes.Topic {
    LiveNotes.Topic(title: title, points: [.init(text: "x", kind: .point)])
}

@MainActor
struct LiveViewTests {
    // MARK: Notes

    @Test func currentTopicIsTheModelsOrElseTheNewest() throws {
        let topics = [topic("A"), topic("B"), topic("C")]
        let named = try #require(LiveNotesView.Layout(LiveNotes(currentTopic: 1, topics: topics)))
        #expect(named.current == 1 && named.previous == [0, 2])
        let unnamed = try #require(LiveNotesView.Layout(LiveNotes(currentTopic: nil, topics: topics)))
        #expect(unnamed.current == 2 && unnamed.previous == [0, 1])
        let outOfRange = try #require(LiveNotesView.Layout(LiveNotes(currentTopic: 7, topics: topics)))
        #expect(outOfRange.current == 2)
        #expect(LiveNotesView.Layout(LiveNotes(currentTopic: 0, topics: [])) == nil)
    }

    @Test func pointKindsHaveLabels() {
        #expect(LiveNotesView.tag(for: .point) == nil)
        #expect(LiveNotesView.tag(for: .decision) == "keputusan")
        #expect(LiveNotesView.tag(for: .actionItem) == "action item")
        #expect(LiveNotesView.tag(for: .openQuestion) == "pertanyaan")
    }

    @Test func updatedLabelIsRelativeInIndonesian() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(LiveNotesView.updatedLabel(now.addingTimeInterval(-20), now: now) == "Diperbarui baru saja")
        // A clock that ran slightly ahead isn't "in 5 seconds".
        #expect(LiveNotesView.updatedLabel(now.addingTimeInterval(5), now: now) == "Diperbarui baru saja")
        #expect(LiveNotesView.updatedLabel(now.addingTimeInterval(-61), now: now) == "Diperbarui 1 menit yang lalu")
        #expect(LiveNotesView.updatedLabel(now.addingTimeInterval(-150), now: now) == "Diperbarui 2 menit yang lalu")
    }

    @Test func placeholderCopy() {
        #expect(LiveNotesView.placeholder == "Catatan pertama muncul sekitar 2–3 menit setelah percakapan dimulai.")
    }

    // MARK: Meta line

    @Test func metaLineNamesSourceLanguageAndMic() {
        #expect(LiveMeetingView.metaLine(
            source: .app(bundleID: "us.zoom.xos", name: "Zoom"), language: "id-ID", mic: "AirPods Pro")
            == "Zoom · Bahasa Indonesia · AirPods Pro")
        #expect(LiveMeetingView.metaLine(source: .systemWide, language: "en-US", mic: nil)
            == "Semua audio sistem · Bahasa Inggris")
    }

    // MARK: Column

    /// 40 pt margins while the column still gets 480 pt; 16 pt below that,
    /// as in an 820 pt window with the sidebar and the transcript open.
    @Test func columnKeepsWideMarginsUntilItGetsNarrow() {
        #expect(LiveMeetingView.sidePadding(forWidth: 840) == 40)
        #expect(LiveMeetingView.sidePadding(forWidth: 560) == 40)
        #expect(LiveMeetingView.sidePadding(forWidth: 559) == 16)
        #expect(LiveMeetingView.sidePadding(forWidth: 820 - 240 - 260) == 16)
    }

    // MARK: Live strip

    @Test func stripShowsNothingBeforeAnyoneSpoke() {
        #expect(LiveStrip.Caption.latest(in: Transcript()) == nil)
    }

    @Test func stripShowsTheLastLineAndWhoSaidIt() {
        var transcript = Transcript()
        transcript.apply(.final("Pagi semua", 1, 2), channel: .meeting, offset: 0, now: 2)
        transcript.apply(.final("Pagi", 3, 4), channel: .mic, offset: 0, now: 4)
        #expect(LiveStrip.Caption.latest(in: transcript)
            == LiveStrip.Caption(speaker: "Saya", isMe: true, final: "Pagi", pending: nil))
    }

    /// The words still changing follow their speaker's last line; another
    /// speaker's last line isn't shown with them.
    @Test func stripFollowsWhoIsSpeakingNow() {
        var transcript = Transcript()
        transcript.apply(.final("Oke, masih masuk budget.", 1, 2), channel: .meeting, offset: 0, now: 2)
        transcript.apply(volatile("Yang penting jangan bentrok"), channel: .meeting, offset: 0, now: 3)
        #expect(LiveStrip.Caption.latest(in: transcript) == LiveStrip.Caption(
            speaker: "Lainnya", isMe: false, final: "Oke, masih masuk budget.", pending: "Yang penting jangan bentrok"))

        transcript.apply(.final("Yang penting jangan bentrok.", 3, 4), channel: .meeting, offset: 0, now: 4)
        transcript.apply(volatile("Setuju"), channel: .mic, offset: 0, now: 5)
        #expect(LiveStrip.Caption.latest(in: transcript)
            == LiveStrip.Caption(speaker: "Saya", isMe: true, final: nil, pending: "Setuju"))

        // The meeting goes first when both are speaking.
        transcript.apply(volatile("Jadi"), channel: .meeting, offset: 0, now: 6)
        #expect(LiveStrip.Caption.latest(in: transcript)?.pending == "Jadi")
        #expect(LiveStrip.Caption.latest(in: transcript)?.final == "Yang penting jangan bentrok.")
    }

    /// The strip names a speaker the way the transcript does.
    @Test func stripNamesSpeakersLikeTheTranscript() {
        let line = TranscriptLine(channel: .meeting, speaker: .remote(2), text: "Setuju", start: 1, end: 2)
        var transcript = Transcript(lines: [line])
        #expect(LiveStrip.Caption.latest(in: transcript)
            == LiveStrip.Caption(speaker: "Pembicara 2", isMe: false, final: "Setuju", pending: nil))
        #expect(LiveStrip.Caption.latest(in: transcript)?.speaker == TranscriptView.label(.remote(2)))
        // Words still changing have no speaker of their own yet: the line's speaker stands.
        transcript.apply(volatile("Kalau begitu"), channel: .meeting, offset: 0, now: 3)
        #expect(LiveStrip.Caption.latest(in: transcript)?.speaker == "Pembicara 2")
    }

    private func volatile(_ text: String) -> TranscriptUpdate {
        TranscriptUpdate(text: text, isFinal: false, span: nil)
    }

    // MARK: Level meter

    @Test func levelMeterFollowsDecibels() {
        #expect(RecordingCapsule.fraction(level: 0) == 0)
        #expect(RecordingCapsule.fraction(level: 0.001) == 0)
        #expect(abs(RecordingCapsule.fraction(level: 0.1) - 0.6) < 0.0001)
        #expect(RecordingCapsule.fraction(level: 1) == 1)
        #expect(RecordingCapsule.fraction(level: 2) == 1)
    }

    // MARK: Notices

    @Test func closedNoticesStayClosedUntilTheyGoAway() {
        let notices: [MeetingNotice] = [.silent, .speakerOutput, .liveNotesDelayed]
        let closed: Set<String> = [MeetingNotice.speakerOutput.id]
        #expect(NoticeBanner.visible(notices, closed: closed) == [.silent, .liveNotesDelayed])
        // Still posted: still closed.
        #expect(NoticeBanner.stillClosed(closed, notices: notices) == closed)
        // Dropped, so it shows again if posted later.
        #expect(NoticeBanner.stillClosed(closed, notices: [.silent]).isEmpty)
    }
}
