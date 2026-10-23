import AVFoundation
import CoreAudio
import Testing
@testable import Notulen

struct AudioTests {
    @Test func converterResamplesTo16kMonoInt16() throws {
        // 4800 frames, 48 kHz, 2 ch, float, 440 Hz sine
        var converter = AudioConverter(target: .mono16kInt16)
        let out = try converter.convert(sine48kStereo(frames: 4800))
        #expect(out.format.sampleRate == 16_000 && out.format.channelCount == 1 && out.format.commonFormat == .pcmFormatInt16)
        #expect((1_590...1_610).contains(Int(out.frameLength)))
    }

    @Test(arguments: [false, true])
    func converterKeepsUpAcrossChunks(interleaved: Bool) throws {
        // 3 × 4800 frames at 48 kHz is 4800 frames at 16 kHz, minus a few of resampler latency.
        var converter = AudioConverter(target: .mono16kInt16)
        var total: AVAudioFrameCount = 0
        for chunk in 0..<3 {
            total += try converter.convert(
                sine48kStereo(frames: 4800, startingAt: chunk * 4800, interleaved: interleaved)).frameLength
        }
        #expect(total >= 4_790)
    }

    @Test(arguments: [1, 2, 4] as [AVAudioChannelCount])
    func micTapsAnyChannelCountAtHardwareRate(channels: AVAudioChannelCount) throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
        let hardware = AVAudioFormat(standardFormatWithSampleRate: 44_100, channelLayout: layout)
        #expect(hardware.channelCount == channels)
        let format = try #require(MicCapture.tapFormat(forHardware: hardware))
        #expect(format.sampleRate == 44_100)
    }

    @Test func appNotRunningMessageIsIndonesian() {
        #expect(ProcessTapCapture.Failure.appNotRunning("Zoom").errorDescription
            == "Zoom tidak sedang berjalan. Buka app meeting-nya dulu, atau pilih Semua audio sistem.")
    }

    @Test func micMessagesAreIndonesian() {
        #expect(MicCapture.Failure.permissionDenied.errorDescription
            == "Akses mikrofon mati. Nyalakan di Pengaturan Sistem › Privasi & Keamanan › Mikrofon.")
        #expect(MicCapture.Failure.noInputDevice.errorDescription == "Mikrofon tidak ditemukan.")
    }

    @Test func onlyTheInternalSpeakerCountsAsBuiltInSpeaker() {
        let builtIn = kAudioDeviceTransportTypeBuiltIn
        let internalSpeaker: UInt32 = 0x6973_706B  // 'ispk'
        let headphones: UInt32 = 0x6864_706E  // 'hdpn'
        #expect(OutputRoute.isBuiltInSpeaker(transportType: builtIn, dataSource: internalSpeaker))
        // Headphones in the Mac's jack are built-in too.
        #expect(!OutputRoute.isBuiltInSpeaker(transportType: builtIn, dataSource: headphones))
        #expect(!OutputRoute.isBuiltInSpeaker(transportType: kAudioDeviceTransportTypeBluetooth, dataSource: internalSpeaker))
    }
}

/// A 440 Hz sine at 48 kHz, stereo, float: the shape a tap or mic delivers.
/// `startingAt` continues the wave from an earlier chunk.
private func sine48kStereo(
    frames: AVAudioFrameCount, startingAt start: Int = 0, interleaved: Bool = false
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let samples = buffer.floatChannelData!
    for frame in 0..<Int(frames) {
        let value = 0.5 * sinf(2 * .pi * 440 * Float(start + frame) / 48_000)
        for channel in 0..<2 {
            if interleaved {
                samples[0][frame * 2 + channel] = value
            } else {
                samples[channel][frame] = value
            }
        }
    }
    return buffer
}
