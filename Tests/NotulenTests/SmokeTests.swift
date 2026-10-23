import Foundation
import Testing
@testable import Notulen

private let sample = LiveNotes(currentTopic: 1, topics: [
    .init(title: "Progres rilis v2.3", points: [.init(text: "Rilis mundur seminggu.", kind: .decision)]),
    .init(title: "Migrasi database ke Postgres 17", points: [
        .init(text: "Perkiraan downtime 30 menit jika migrasi biasa.", kind: .point),
        .init(text: "Belum ada keputusan siapa yang memegang migrasi.", kind: .openQuestion),
    ]),
])

@MainActor @Test func contentViewInstantiates() { _ = ContentView(showsNewMeeting: .constant(false)) }

@MainActor @Test func transcriptViewInstantiates() { _ = TranscriptView(transcript: Transcript()) }

@MainActor @Test func liveNotesViewInstantiates() { _ = LiveNotesView(notes: sample, updatedAt: .now, problem: nil) }

@MainActor @Test func liveScreenViewsInstantiate() {
    _ = LiveMeetingView()
    _ = LiveNotesView(notes: nil, updatedAt: nil, problem: "Isi kunci API Claude di Pengaturan.")
    _ = LiveStrip()
    _ = RecordingCapsule()
    _ = NoticeBanner(notices: [.silent, .speakerOutput])
}
