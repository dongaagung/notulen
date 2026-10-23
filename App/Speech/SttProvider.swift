import Foundation

/// A partial or final piece of recognized speech.
struct TranscriptUpdate: Equatable, Sendable {
    var text: String
    /// Final text won't change again. Volatile text is replaced by later updates.
    var isFinal: Bool
    /// Where the text sits in the audio, in seconds from this stream's start.
    /// Nil when the recognizer gave no usable range.
    var span: TimeSpan?
}

/// Speech-to-text engine. Each call transcribes one audio stream until the
/// stream ends, then finishes its own output.
protocol SttProvider: Sendable {
    /// Gets ready to transcribe, such as downloading the on-device model,
    /// reporting progress from 0 to 1 while that takes a while.
    func prepare(progress: (@Sendable (Double) -> Void)?) async throws
    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptUpdate, any Error>
}
