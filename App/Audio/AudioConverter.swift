import AVFoundation

extension AVAudioFormat {
    /// 16 kHz mono Int16, interleaved: how meeting audio waits in memory for
    /// speaker separation.
    static let mono16kInt16 = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
}

/// Converts capture-format buffers (e.g. 48 kHz stereo float) to another
/// format, such as the analyzer's or `mono16kInt16`, keeping resampler state
/// across calls.
struct AudioConverter {
    enum Failure: LocalizedError {
        case conversionFailed

        var errorDescription: String? { "Gagal mengonversi audio." }
    }

    let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) {
        self.target = target
    }

    mutating func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == target { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { throw Failure.conversionFailed }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw Failure.conversionFailed
        }
        let input = SlicedInput(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { packetCount, inputStatus in
            if let next = input.next(packetCount) {
                inputStatus.pointee = .haveData
                return next
            }
            // .noDataNow (not .endOfStream) keeps the converter usable for the next buffer.
            inputStatus.pointee = .noDataNow
            return nil
        }
        if status == .error { throw error ?? Failure.conversionFailed }
        return output
    }
}

/// Hands out its buffer once, in pieces no larger than the converter asks
/// for. The converter's input block is called more than once per `convert`.
/// Given more than it asked for (over 4096 frames), the resampler converts
/// only what it asked for and holds the rest until the next call: 4800
/// frames at 48 kHz then come out as 1360 frames at 16 kHz instead of 1600.
private final class SlicedInput {
    private let buffer: AVAudioPCMBuffer
    private var offset: AVAudioFrameCount = 0

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    /// Up to `count` frames that weren't handed out yet; nil once all were.
    func next(_ count: AVAudioPacketCount) -> AVAudioPCMBuffer? {
        let remaining = buffer.frameLength - offset
        guard remaining > 0 else { return nil }
        let length = min(count, remaining)
        defer { offset += length }
        if offset == 0, length == remaining { return buffer }
        return buffer.copied(from: offset, count: length)
    }
}

private extension AVAudioPCMBuffer {
    /// Copy of `count` frames starting at frame `start`.
    func copied(from start: AVAudioFrameCount, count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
        copy.frameLength = count
        // Per channel buffer when deinterleaved, which is what mBytesPerFrame counts then.
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData + Int(start) * bytesPerFrame, Int(count) * bytesPerFrame)
        }
        return copy
    }
}
