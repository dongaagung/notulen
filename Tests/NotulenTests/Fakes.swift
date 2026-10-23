import AVFoundation
import Foundation
import Synchronization
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
    /// Thrown by `resume()`, to fake a mic that can't come back on.
    var resumeError: (any Error)?
    var onDeviceChange: (@MainActor (String) -> Void)?
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
        // Like the real captures: the oldest chunks go once 128 wait unread.
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .bufferingNewest(128))
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

    func resume() throws {
        if let resumeError { throw resumeError }
        resumeCount += 1
    }

    /// Reports a move to the input device `name`, as the real mic does
    /// after restarting on a new headset.
    func changeDevice(to name: String) {
        onDeviceChange?(name)
    }

    /// Forwards `chunk`, or 0.1 s of audible sound in this capture's layout.
    func send(_ chunk: AudioChunk? = nil) {
        continuation?.yield(chunk ?? .audible(channels: channels))
    }
}

/// Stands in for `OutputRouteMonitor`: the test says where the meeting's
/// sound comes out.
@MainActor
final class FakeOutputRoute: OutputRouteMonitoring {
    var onChange: (@MainActor () -> Void)?
    var isBuiltInSpeaker = false
    private(set) var isMonitoring = false

    func start() { isMonitoring = true }

    func stop() { isMonitoring = false }

    /// Moves the sound to or from the Mac's speakers, as plugging headphones
    /// in or out does, and reports it while monitoring.
    func change(toBuiltInSpeaker builtIn: Bool) {
        isBuiltInSpeaker = builtIn
        if isMonitoring { onChange?() }
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
    /// How long it takes before reading audio, like the real recognizer
    /// setting up its analyzer.
    var startDelay = Duration.zero
    /// Counts every chunk read.
    var received: ReceivedAudio?
    /// `prepare` throws, like a speech model that can't be installed.
    var failsToPrepare = false

    struct PrepareFailure: Error {}

    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        if failsToPrepare { throw PrepareFailure() }
    }

    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptUpdate, any Error> {
        let (meeting, mic, startDelay, received) = (meeting, mic, startDelay, received)
        return AsyncThrowingStream { output in
            let task = Task {
                if startDelay > .zero { try? await Task.sleep(for: startDelay) }
                var heard = false
                for await chunk in audio {
                    let channel = chunk.buffer.format.channelCount > 1 ? Channel.meeting : .mic
                    received?.add(channel)
                    guard !heard else { continue }
                    heard = true
                    for update in channel == .meeting ? meeting : mic {
                        output.yield(update)
                    }
                }
                output.finish()
            }
            output.onTermination = { _ in task.cancel() }
        }
    }
}

/// Chunks a `FakeSpeech` read, per channel.
final class ReceivedAudio: Sendable {
    private let counts = Mutex<[Channel: Int]>([:])

    func add(_ channel: Channel) {
        counts.withLock { $0[channel, default: 0] += 1 }
    }

    func count(_ channel: Channel) -> Int {
        counts.withLock { $0[channel, default: 0] }
    }
}

extension TranscriptUpdate {
    static func final(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptUpdate {
        TranscriptUpdate(text: text, isFinal: true, span: TimeSpan(start: start, end: end))
    }
}

extension PowerGuard {
    /// Takes no real power assertion and hears sleep and wake only from
    /// `notifications`, never the system's. `preventsSleep` still follows
    /// `begin()`, sleep and `end()`.
    static func fake(notifications: NotificationCenter = NotificationCenter()) -> PowerGuard {
        PowerGuard(notificationCenter: notifications, takesSystemAssertion: false)
    }
}

/// A clock that only moves when the test moves it.
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(_ seconds: TimeInterval) {
        now += seconds
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

/// Answers requests from `replies` in order; the last reply repeats once
/// the queue runs out.
final class FakeLLMClient: LLMClient, @unchecked Sendable {
    let providerName = "Fake"
    private let lock = NSLock()
    private var replies: [Result<String, any Error>]
    private var recorded: [LLMRequest] = []

    init(replies: [Result<String, any Error>]) { self.replies = replies }

    convenience init(reply: String) { self.init(replies: [.success(reply)]) }

    private(set) var requests: [LLMRequest] {
        get { lock.withLock { recorded } }
        set { lock.withLock { recorded = newValue } }
    }

    func complete(_ request: LLMRequest) async throws -> String {
        let reply: Result<String, any Error> = lock.withLock {
            recorded.append(request)
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
        return try reply.get()
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(try await complete(request))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
