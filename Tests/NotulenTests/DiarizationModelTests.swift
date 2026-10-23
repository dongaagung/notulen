import FluidAudio
import Testing
@testable import Notulen

struct DiarizationModelTests {
    /// Runs only where the models are downloaded (`make models`).
    @Test(.enabled(if: DiarizationModels.directory() != nil))
    func modelsLoadOffline() async throws {
        ModelHub.offlineMode = true
        _ = try await OfflineDiarizerModels.load(from: DiarizationModels.directory()!)
    }
}
