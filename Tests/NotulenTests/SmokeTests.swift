import Testing
@testable import Notulen

@MainActor @Test func contentViewInstantiates() { _ = ContentView(showsNewMeeting: .constant(false)) }

@MainActor @Test func transcriptViewInstantiates() { _ = TranscriptView(transcript: Transcript()) }
