import AVFoundation
import Foundation
@testable import Notulen

/// A capture channel that forwards the chunks it's given. Stands in for the
/// meeting tap or the mic, and counts mic pauses and resumes.
@MainActor
final class FakeCapture: MicCapturing {
    /// Channel layout of the chunks `send()` makes up: the real meeting tap
    /// delivers stereo, the mic mono. `FakeSpeech` tells the channels apart
    /// by it.
    let channels: AVAudioChannelCount
    /// Thrown by `start()`, to fake a channel that can't start.
    var startError: (any Error)?
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private var chunks: [AudioChunk]
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    /// Stereo, like the meeting tap.
    static func meeting(_ chunks: [AudioChunk] = []) -> FakeCapture { FakeCapture(channels: 2, chunks: chunks) }
    /// Mono, like the mic.
    static func mic(_ chunks: [AudioChunk] = []) -> FakeCapture { FakeCapture(channels: 1, chunks: chunks) }

    /// `chunks` are forwarded as soon as capture starts.
    init(channels: AVAudioChannelCount, chunks: [AudioChunk] = []) {
        self.channels = channels
        self.chunks = chunks
    }

    static func requestPermission() async -> Bool { true }

    var isCapturing: Bool { continuation != nil }

    func start() throws -> AsyncStream<AudioChunk> {
        if let startError { throw startError }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        chunks.forEach { continuation.yield($0) }
        chunks = []
        self.continuation = continuation
        return stream
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }

    func pause() { pauseCount += 1 }

    func resume() throws { resumeCount += 1 }

    /// Forwards `chunk`, or 0.1 s of audible sound in this capture's layout.
    func send(_ chunk: AudioChunk? = nil) {
        continuation?.yield(chunk ?? .audible(channels: channels))
    }
}

extension AudioChunk {
    /// 48 kHz float audio at a constant level, loud enough to count as sound.
    static func audible(channels: AVAudioChannelCount, frames: AVAudioFrameCount = 4_800) -> AudioChunk {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] = 0.1
            }
        }
        return AudioChunk(buffer: buffer)
    }
}

/// Recognizes prepared updates instead of speech. Tells the channels apart
/// the way the real captures differ: stereo audio is the meeting, mono the
/// mic. A channel's updates come out when its first chunk arrives; the
/// output ends when the audio does.
struct FakeSpeech: SttProvider {
    var meeting: [TranscriptUpdate] = []
    var mic: [TranscriptUpdate] = []

    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {}

    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptUpdate, any Error> {
        let (meeting, mic) = (meeting, mic)
        return AsyncThrowingStream { output in
            let task = Task {
                var heard = false
                for await chunk in audio where !heard {
                    heard = true
                    for update in chunk.buffer.format.channelCount > 1 ? meeting : mic {
                        output.yield(update)
                    }
                }
                output.finish()
            }
            output.onTermination = { _ in task.cancel() }
        }
    }
}

extension TranscriptUpdate {
    static func final(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptUpdate {
        TranscriptUpdate(text: text, isFinal: true, span: TimeSpan(start: start, end: end))
    }
}

/// Polls `condition` every 10 ms until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
