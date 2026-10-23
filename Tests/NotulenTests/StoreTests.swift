import Foundation
import Testing
@testable import Notulen

@MainActor
struct StoreTests {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "NotulenTests-\(UUID().uuidString)")

    private func makeStore() -> AppStore {
        AppStore(files: JSONFileStore(directory: directory), keychainPrefix: "test-\(UUID().uuidString)-")
    }

    @Test func formatsUnderAnHour() {
        #expect(MeetingTime.format(312) == "05:12")
        #expect(MeetingTime.format(0) == "00:00")
    }

    @Test func formatsOverAnHour() {
        #expect(MeetingTime.format(4514) == "1:15:14")
        #expect(MeetingTime.format(3600) == "1:00:00")
    }

    @Test func meetingRoundTripsThroughStore() {
        let meeting = Meeting(
            title: "Sprint review", startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 4_600), status: .ready, language: "id-ID",
            audioSource: .app(bundleID: "us.zoom.xos", name: "Zoom"),
            gaps: [Gap(span: TimeSpan(start: 10, end: 20), reason: .sleep)],
            micOff: [TimeSpan(start: 30, end: 40)],
            speakers: [SpeakerInfo(id: .remote(1), name: "Budi")],
            speakerAssignments: [SpeakerAssignment(line: UUID(), speaker: .remote(1))],
            merges: [SpeakerMerge(from: .remote(2), to: .remote(1))],
            actionItemsDone: ["a1"], notionPageID: "page", failure: nil)
        makeStore().save(meeting)
        #expect(makeStore().meetings == [meeting])
    }

    @Test func meetingsAreSortedNewestFirst() {
        let store = makeStore()
        let old = Meeting(title: "Old", startedAt: Date(timeIntervalSince1970: 100), status: .ready, language: "id-ID", audioSource: .systemWide)
        let new = Meeting(title: "New", startedAt: Date(timeIntervalSince1970: 200), status: .ready, language: "id-ID", audioSource: .systemWide)
        store.save(old)
        store.save(new)
        #expect(store.meetings.map(\.title) == ["New", "Old"])
        #expect(makeStore().meetings.map(\.title) == ["New", "Old"])
    }

    @Test func olderMeetingFileKeepsDefaults() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"X","startedAt":"2026-10-22T09:00:00Z","status":"ready","language":"id-ID","audioSource":{"systemWide":{}}}"#
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appending(path: "old.json"))
        let meeting = try #require(try JSONFileStore(directory: directory).load(Meeting.self, from: "old.json"))
        #expect(meeting.gaps.isEmpty && meeting.speakers.isEmpty && meeting.actionItemsDone.isEmpty)
        #expect(meeting.endedAt == nil && meeting.notionPageID == nil && meeting.failure == nil)
    }

    @Test func deleteRemovesMeetingFolder() throws {
        let store = makeStore()
        let meeting = Meeting(title: "X", startedAt: Date(timeIntervalSince1970: 100), status: .ready, language: "id-ID", audioSource: .systemWide)
        store.save(meeting)
        let transcript = try #require(store.transcriptURL(for: meeting.id))
        try Data("{}\n".utf8).write(to: transcript)
        let folder = transcript.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: folder.path))
        store.delete(meeting)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(store.meetings.isEmpty)
        #expect(makeStore().meetings.isEmpty)
    }

    @Test func settingsPersistAcrossLaunches() {
        let first = makeStore()
        first.settings.textScale = 1.6
        first.settings.vocabulary = ["Altara"]
        let second = makeStore()
        #expect(second.settings.textScale == 1.6)
        #expect(second.settings.vocabulary == ["Altara"])
    }

    @Test func settingsDefaultToIndonesian() {
        #expect(AppSettings().localeIdentifier == "id-ID")
    }

    @Test func olderSettingsFileKeepsDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"localeIdentifier":"en-US"}"#.utf8))
        #expect(settings.localeIdentifier == "en-US")
        #expect(settings.textScale == TextScale.standard && settings.vocabulary.isEmpty)
    }

    @Test func meetingAudioSourceLabel() {
        #expect(MeetingAudioSource.systemWide.label == "Semua audio sistem")
        #expect(MeetingAudioSource.app(bundleID: "us.zoom.xos", name: "Zoom").label == "Zoom")
    }

    @Test func remoteSpeakerIDs() {
        #expect(SpeakerID.remote(3).rawValue == "s3")
        #expect(SpeakerID(rawValue: "s12")?.remoteNumber == 12)
        #expect(SpeakerID.me.remoteNumber == nil)
    }
}
