import AVFoundation

/// One block of captured audio, copied out of the capture callback so it can
/// cross into the speech recognizer's task. Kept in memory only, never written
/// to disk.
struct AudioChunk: @unchecked Sendable {
    // Unchecked: each buffer is a private copy that nothing mutates after it's sent.
    let buffer: AVAudioPCMBuffer
}

extension AVAudioPCMBuffer {
    /// Deep copy. Capture callbacks reuse or free their buffers once they return.
    func copied() -> AVAudioPCMBuffer? {
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)
        else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}
