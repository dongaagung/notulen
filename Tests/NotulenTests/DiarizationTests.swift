import AVFoundation
import FluidAudio
import Foundation
import Testing
@testable import Notulen

struct DiarizationTests {
    private func line(_ start: TimeInterval, _ end: TimeInterval, _ channel: Channel = .meeting) -> TranscriptLine {
        TranscriptLine(channel: channel, speaker: channel == .mic ? .me : .others, text: "x", start: start, end: end)
    }

    private func segment(_ label: String, _ start: TimeInterval, _ end: TimeInterval) -> DiarizedSegment {
        DiarizedSegment(label: label, start: start, end: end)
    }

    /// Who each line went to, in `lines` order; nil for a line left as others.
    private func speakers(
        of lines: [TranscriptLine], _ result: (assignments: [SpeakerAssignment], speakers: [SpeakerInfo])
    ) -> [SpeakerID?] {
        lines.map { line in result.assignments.first { $0.line == line.id }?.speaker }
    }

    // MARK: Matching

    @Test func lineTakesSpeakerWithMostOverlap() {
        let lines = [line(10, 14)]
        let result = SpeakerMatcher.assign(lines: lines, segments: [segment("A", 9, 11), segment("B", 11, 15)])
        #expect(speakers(of: lines, result) == [.remote(1)])
        #expect(result.speakers == [SpeakerInfo(id: .remote(1), name: nil)])
        // B's number: A never got a line.
        let first = [line(0, 2)] + lines
        let both = SpeakerMatcher.assign(
            lines: first, segments: [segment("A", 0, 2), segment("A", 9, 11), segment("B", 11, 15)])
        #expect(speakers(of: first, both) == [.remote(1), .remote(2)])
    }

    /// A speaker's turns add up: two short turns beat one longer one.
    @Test func overlapAddsUpPerSpeaker() {
        let lines = [line(0, 2), line(10, 20)]
        let result = SpeakerMatcher.assign(
            lines: lines,
            segments: [segment("B", 0, 2), segment("A", 10, 13), segment("B", 13, 17), segment("A", 17, 20)])
        // A has 6 s of 10–20, B 4 s in one turn.
        #expect(speakers(of: lines, result) == [.remote(1), .remote(2)])
    }

    /// Equal overlap: the speaker whose turn started first.
    @Test func tieGoesToTheEarliestSegment() {
        let lines = [line(0, 1), line(10, 14)]
        let result = SpeakerMatcher.assign(
            lines: lines, segments: [segment("B", 0, 1), segment("B", 12, 16), segment("A", 8, 12)])
        // 2 s each of 10–14; A's turn started first.
        #expect(speakers(of: lines, result) == [.remote(1), .remote(2)])
    }

    @Test func numbersBySpeakingOrder() {
        let lines = [line(0, 4), line(5, 9), line(10, 14), line(15, 19)]
        let result = SpeakerMatcher.assign(
            lines: lines,
            segments: [segment("S2", 0, 4.5), segment("S1", 4.5, 9.5), segment("S3", 9.5, 14.5), segment("S2", 14.5, 20)])
        #expect(speakers(of: lines, result) == [.remote(1), .remote(2), .remote(3), .remote(1)])
        #expect(result.speakers == [
            SpeakerInfo(id: .remote(1), name: nil), SpeakerInfo(id: .remote(2), name: nil),
            SpeakerInfo(id: .remote(3), name: nil),
        ])
    }

    /// The journal can be slightly out of order; numbers follow meeting time.
    @Test func numbersFollowTimeNotJournalOrder() {
        let lines = [line(10, 14), line(0, 4)]
        let result = SpeakerMatcher.assign(lines: lines, segments: [segment("S1", 10, 14), segment("S2", 0, 4)])
        #expect(speakers(of: lines, result) == [.remote(2), .remote(1)])
    }

    @Test func micLinesAreIgnored() {
        let lines = [line(0, 4, .mic), line(5, 9)]
        let result = SpeakerMatcher.assign(lines: lines, segments: [segment("S1", 0, 4), segment("S2", 5, 9)])
        #expect(speakers(of: lines, result) == [nil, .remote(1)])
        #expect(result.speakers == [SpeakerInfo(id: .remote(1), name: nil)])
    }

    @Test func nearbySegmentWithinTolerance() {
        let lines = [line(20, 21)]
        let near = SpeakerMatcher.assign(lines: lines, segments: [segment("S1", 21.5, 25)])
        #expect(speakers(of: lines, near) == [.remote(1)])
        let far = SpeakerMatcher.assign(lines: lines, segments: [segment("S1", 23, 25)])
        #expect(far.assignments.isEmpty)
        #expect(far.speakers.isEmpty)
        // The nearest one wins, before or after the line.
        let two = [line(0, 1)] + lines
        let between = SpeakerMatcher.assign(
            lines: two, segments: [segment("S1", 0, 1), segment("S1", 17, 19.2), segment("S2", 21.5, 25)])
        #expect(speakers(of: two, between) == [.remote(1), .remote(2)])
        #expect(SpeakerMatcher.nearbyTolerance == 1.0)
    }

    @Test func noSegmentsLeaveEveryLineToOthers() {
        let result = SpeakerMatcher.assign(lines: [line(0, 4), line(5, 9)], segments: [])
        #expect(result.assignments.isEmpty)
        #expect(result.speakers.isEmpty)
    }

    // MARK: Diarizer

    /// FluidAudio's times are into the stored audio, which skips the gaps
    /// where the Mac slept; a turn across a gap becomes two.
    @Test func turnsSplitAtRecordingGaps() {
        let buffer = MeetingAudioBuffer.filled(seconds: 10)
        buffer.beginSegment(atMeetingTime: 100)
        buffer.append(.silence(seconds: 10))
        func turn(_ label: String, _ start: Float, _ end: Float) -> TimedSpeakerSegment {
            TimedSpeakerSegment(speakerId: label, embedding: [], startTimeSeconds: start, endTimeSeconds: end, qualityScore: 1)
        }
        let segments = SpeakerDiarizer.meetingSegments(
            [turn("S1", 2, 10), turn("S2", 8, 13), turn("S1", 12, 19.5), turn("S2", 19.5, 25)], in: buffer)
        #expect(segments == [
            segment("S1", 2, 10),
            segment("S2", 8, 10), segment("S2", 100, 103),
            segment("S1", 102, 109.5),
            segment("S2", 109.5, 110),
        ])
    }

    /// Runs only where the models are downloaded (`make models`).
    @Test(.enabled(if: DiarizationModels.directory() != nil))
    func silentAudioYieldsNoSegments() async throws {
        ModelHub.offlineMode = true
        let diarizer = SpeakerDiarizer(modelsDirectory: try #require(DiarizationModels.directory()))
        let buffer = MeetingAudioBuffer.filled(seconds: 5)
        #expect(try await diarizer.diarize(buffer) == [])
    }

    // MARK: Finisher

    @MainActor @Test func diarizationFailureFallsBackToOthers() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "NotulenTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(files: JSONFileStore(directory: root), keychainPrefix: "test-\(UUID().uuidString)-")
        let meeting = Meeting(
            title: "", startedAt: Date(timeIntervalSince1970: 1_800_000_000), status: .processing,
            language: "id-ID", audioSource: .systemWide)
        store.save(meeting)
        let journal = try TranscriptJournal(url: #require(store.transcriptURL(for: meeting.id)))
        try journal.append(TranscriptLine(
            channel: .meeting, speaker: .others, text: "Rilis versi baru diundur seminggu", start: 1, end: 4))
        journal.close()
        let fixture = try #require(Bundle.module.url(forResource: "minutes", withExtension: "json", subdirectory: "Fixtures"))
        let llm = FakeLLMClient(reply: try String(contentsOf: fixture, encoding: .utf8))
        let template = try PromptTemplate.load("minutes")
        let diarizer = FakeDiarizer(.failure(OfflineDiarizationError.processingFailed("test")))
        let finisher = MeetingFinisher(store: store, diarizer: diarizer) { MinutesWriter(client: llm, template: template) }
        let audio = MeetingAudioBuffer.filled(seconds: 5)

        await finisher.finish(meeting.id, audio: audio)

        let finished = try #require(store.meeting(meeting.id))
        #expect(diarizer.samplesHeard == [80_000])
        #expect(finished.status == .ready)
        #expect(finished.minutes != nil)
        #expect(finished.speakerAssignments.isEmpty)
        #expect(finished.speakers.isEmpty)
        #expect(llm.requests.first?.messages.first?.content.contains("[[others]]: Rilis") == true)
        #expect(audio.sampleCount == 0)
        #expect(finisher.running.isEmpty)
    }
}
