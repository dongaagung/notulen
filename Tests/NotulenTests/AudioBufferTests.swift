import AVFoundation
import Testing

@testable import Notulen

@Suite struct AudioBufferTests {
    private func pcm(_ samples: [Int16]) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: .mono16kInt16, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, s) in samples.enumerated() { buffer.int16ChannelData![0][i] = s }
        return buffer
    }

    private func read(_ b: MeetingAudioBuffer, offset: Int, count: Int) throws -> [Float] {
        var out = [Float](repeating: 0, count: count)
        try out.withUnsafeMutableBufferPointer {
            try b.copySamples(into: $0.baseAddress!, offset: offset, count: count)
        }
        return out
    }

    @Test func copiesAsFloat() throws {
        let buffer = MeetingAudioBuffer(maxSamples: 100, chunkSamples: 8)
        buffer.beginSegment(atMeetingTime: 0)
        buffer.append(pcm([16384, -16384]))
        #expect(try read(buffer, offset: 0, count: 2) == [0.5, -0.5])
    }

    @Test func mapsBufferTimeAcrossSegments() {
        let buffer = MeetingAudioBuffer(maxSamples: 100_000, chunkSamples: 4096)
        buffer.beginSegment(atMeetingTime: 0)
        buffer.append(pcm([Int16](repeating: 1, count: 16_000)))
        buffer.beginSegment(atMeetingTime: 100)
        buffer.append(pcm([Int16](repeating: 1, count: 16_000)))
        #expect(buffer.meetingTime(ofBufferTime: 0.5) == 0.5)
        #expect(buffer.meetingTime(ofBufferTime: 1.5) == 100.5)
        #expect(buffer.coveredUntil == 101)
    }

    @Test func stopsAtCap() {
        let buffer = MeetingAudioBuffer(maxSamples: 10, chunkSamples: 4)
        buffer.beginSegment(atMeetingTime: 0)
        #expect(buffer.append(pcm([Int16](repeating: 1, count: 12))) == false)
        #expect(buffer.sampleCount == 10)
        #expect(buffer.append(pcm([1])) == false)
        #expect(buffer.sampleCount == 10)
    }

    @Test func copyCrossesChunkBoundary() throws {
        let buffer = MeetingAudioBuffer(maxSamples: 100, chunkSamples: 4)
        buffer.beginSegment(atMeetingTime: 0)
        buffer.append(pcm(Array(0...9)))
        #expect(try read(buffer, offset: 3, count: 4) == [3, 4, 5, 6].map { Float($0) / 32768 })
    }

    @Test func copyOutOfRangeThrows() {
        let buffer = MeetingAudioBuffer(maxSamples: 100, chunkSamples: 4)
        buffer.beginSegment(atMeetingTime: 0)
        buffer.append(pcm([1, 2, 3]))
        #expect(throws: (any Error).self) { try read(buffer, offset: 2, count: 4) }
    }

    @Test func wipeEmptiesBuffer() {
        let buffer = MeetingAudioBuffer(maxSamples: 100, chunkSamples: 4)
        buffer.beginSegment(atMeetingTime: 0)
        buffer.append(pcm([1, 2, 3, 4, 5]))
        buffer.wipe()
        #expect(buffer.sampleCount == 0)
        #expect(buffer.coveredUntil == nil)
        buffer.beginSegment(atMeetingTime: 0)
        buffer.append(pcm([16384, 8192]))
        #expect(buffer.sampleCount == 2)
        #expect((try? read(buffer, offset: 0, count: 2)) == [0.5, 0.25])
    }

    @Test func coveredUntilIgnoresEmptyTrailingSegment() {
        let buffer = MeetingAudioBuffer(maxSamples: 100_000, chunkSamples: 4096)
        buffer.beginSegment(atMeetingTime: 0)
        buffer.append(pcm([Int16](repeating: 1, count: 16_000)))
        buffer.beginSegment(atMeetingTime: 100)
        #expect(buffer.coveredUntil == 1)
    }

    @Test func coveredUntilStopsAtCap() {
        let buffer = MeetingAudioBuffer(maxSamples: 16_000, chunkSamples: 4000)
        buffer.beginSegment(atMeetingTime: 0)
        buffer.append(pcm([Int16](repeating: 1, count: 16_000)))
        buffer.beginSegment(atMeetingTime: 50)
        buffer.append(pcm([1]))
        #expect(buffer.coveredUntil == 1)
    }
}
