import FluidAudio
import Testing
@testable import Notulen

/// Every test that runs the bundled Core ML models, one at a time: FluidAudio
/// runs side by side can hang Core ML, and the test process with it. Runs
/// only where the models are downloaded (`make models`).
@Suite(.serialized, .enabled(if: DiarizationModels.directory() != nil))
struct DiarizationModelTests {
    /// One diarizer for the suite: it loads the models once and takes one
    /// call at a time.
    static let diarizer = DiarizationModels.directory().map { SpeakerDiarizer(modelsDirectory: $0) }

    @Test(.timeLimit(.minutes(2)))
    func modelsLoadOffline() async throws {
        ModelHub.offlineMode = true
        let directory = try #require(DiarizationModels.directory())
        _ = try await OfflineDiarizerModels.load(from: directory)
    }

    @Test(.timeLimit(.minutes(2)))
    func silentAudioYieldsNoSegments() async throws {
        ModelHub.offlineMode = true
        let diarizer = try #require(Self.diarizer)
        #expect(try await diarizer.diarize(MeetingAudioBuffer.filled(seconds: 5)) == [])
    }
}
