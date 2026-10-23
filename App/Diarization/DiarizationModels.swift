import Foundation

/// Where the bundled diarization models live. FluidAudio's offline loader
/// takes the parent folder that holds `speaker-diarization/`.
enum DiarizationModels {
    /// The app bundle's FluidAudioModels folder, or ./Models under
    /// `swift test` (run from the package root). Nil when neither exists.
    static func directory() -> URL? {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("FluidAudioModels"),
           fm.fileExists(atPath: bundled.path) {
            return bundled
        }
        let local = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Models")
        return fm.fileExists(atPath: local.path) ? local : nil
    }
}
