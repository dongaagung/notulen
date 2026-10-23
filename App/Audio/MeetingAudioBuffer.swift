import AVFoundation

/// Meeting-channel audio for diarization, in RAM only (16 kHz mono Int16,
/// never written to disk). Stored in fixed-size chunks allocated as audio
/// arrives.
///
/// Threading contract: one writer while recording (`append`, `beginSegment`),
/// reads (`sampleCount`, `copySamples`, `meetingTime`, `coveredUntil`) only
/// after recording stops, and `wipe()` once when the buffer is no longer
/// needed. There is no locking, hence `@unchecked Sendable`.
final class MeetingAudioBuffer: @unchecked Sendable {
    static let sampleRate = 16_000.0
    static let maxDuration: TimeInterval = 4 * 3600

    enum Failure: Error {
        case rangeOutOfBounds
    }

    private struct Segment {
        var meetingStart: TimeInterval
        var sampleOffset: Int
    }

    private let maxSamples: Int
    private let chunkSamples: Int
    private var chunks: [UnsafeMutableBufferPointer<Int16>] = []
    private var segments: [Segment] = []
    private(set) var sampleCount = 0

    /// 4 hours of audio in 10-minute chunks.
    convenience init() {
        self.init(
            maxSamples: Int(Self.maxDuration * Self.sampleRate),
            chunkSamples: Int(10 * 60 * Self.sampleRate))
    }

    init(maxSamples: Int, chunkSamples: Int) {
        precondition(maxSamples >= 0 && chunkSamples > 0)
        self.maxSamples = maxSamples
        self.chunkSamples = chunkSamples
    }

    deinit { freeChunks() }

    /// Marks that audio appended from now on starts at `atMeetingTime`
    /// (after start, wake or resume).
    func beginSegment(atMeetingTime: TimeInterval) {
        if let last = segments.last, last.sampleOffset == sampleCount {
            segments[segments.count - 1].meetingStart = atMeetingTime
        } else {
            segments.append(Segment(meetingStart: atMeetingTime, sampleOffset: sampleCount))
        }
    }

    /// Appends a `mono16kInt16` buffer. Returns false once the buffer is full;
    /// samples beyond the cap are dropped.
    @discardableResult
    func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let source = buffer.int16ChannelData?[0] else { return false }
        if segments.isEmpty { beginSegment(atMeetingTime: 0) }
        let incoming = Int(buffer.frameLength)
        let accepted = min(incoming, maxSamples - sampleCount)
        var copied = 0
        while copied < accepted {
            let chunkIndex = sampleCount / chunkSamples
            let inChunk = sampleCount % chunkSamples
            if chunkIndex == chunks.count {
                let chunk = UnsafeMutableBufferPointer<Int16>.allocate(capacity: chunkSamples)
                chunk.initialize(repeating: 0)
                chunks.append(chunk)
            }
            let n = min(accepted - copied, chunkSamples - inChunk)
            (chunks[chunkIndex].baseAddress! + inChunk).update(from: source + copied, count: n)
            copied += n
            sampleCount += n
        }
        return accepted == incoming
    }

    /// Meeting time where the stored audio ends, or nil when empty.
    var coveredUntil: TimeInterval? {
        guard sampleCount > 0, let last = segments.last else { return nil }
        return last.meetingStart + Double(sampleCount - last.sampleOffset) / Self.sampleRate
    }

    /// Converts a time within the stored audio (seconds from its start) to
    /// meeting time, accounting for gaps between segments.
    func meetingTime(ofBufferTime seconds: TimeInterval) -> TimeInterval {
        let sample = Int((seconds * Self.sampleRate).rounded())
        guard let segment = segments.last(where: { $0.sampleOffset <= sample }) ?? segments.first
        else { return seconds }
        return segment.meetingStart + Double(sample - segment.sampleOffset) / Self.sampleRate
    }

    /// Copies samples as Float in [-1, 1] (Int16 / 32768).
    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        guard offset >= 0, count >= 0, offset <= sampleCount, count <= sampleCount - offset else {
            throw Failure.rangeOutOfBounds
        }
        var done = 0
        while done < count {
            let position = offset + done
            let chunk = chunks[position / chunkSamples]
            let inChunk = position % chunkSamples
            let n = min(count - done, chunkSamples - inChunk)
            for i in 0..<n {
                destination[done + i] = Float(chunk[inChunk + i]) / 32768
            }
            done += n
        }
    }

    /// Zeroes every chunk and frees it.
    func wipe() {
        freeChunks()
        segments.removeAll()
        sampleCount = 0
    }

    private func freeChunks() {
        for chunk in chunks {
            chunk.update(repeating: 0)
            chunk.deallocate()
        }
        chunks.removeAll()
    }
}
