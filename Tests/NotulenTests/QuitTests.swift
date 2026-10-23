import Testing
@testable import Notulen

/// What ⌘Q asks before quitting.
@MainActor
struct QuitTests {
    private let recordingQuestion = AppDelegate.QuitQuestion(
        message: "Meeting sedang direkam. Keluar sekarang?", detail: nil)
    private let separationQuestion = AppDelegate.QuitQuestion(
        message: "Pemisahan pembicara sedang berjalan. Keluar sekarang?",
        detail: "Semua suara peserta akan berlabel “Lainnya”.")

    @Test func nothingToLoseQuitsAtOnce() {
        #expect(AppDelegate.quitQuestions(recording: false, steps: []).isEmpty)
        // The minutes are written again at the next launch (Coba lagi).
        #expect(AppDelegate.quitQuestions(recording: false, steps: [.writingMinutes]).isEmpty)
    }

    /// The meeting audio is only in RAM: quitting while speakers are told
    /// apart leaves every remote voice "Lainnya".
    @Test func speakerSeparationAsksFirst() {
        #expect(AppDelegate.quitQuestions(recording: false, steps: [.separatingSpeakers]) == [separationQuestion])
        #expect(AppDelegate.quitQuestions(recording: false, steps: [.writingMinutes, .separatingSpeakers])
            == [separationQuestion])
    }

    @Test func recordingAsksFirstThenSeparation() {
        #expect(AppDelegate.quitQuestions(recording: true, steps: []) == [recordingQuestion])
        #expect(AppDelegate.quitQuestions(recording: true, steps: [.separatingSpeakers])
            == [recordingQuestion, separationQuestion])
    }
}
