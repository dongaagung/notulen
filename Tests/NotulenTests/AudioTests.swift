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
private func sine48kStereo(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<2 {
        for frame in 0..<Int(frames) {
            buffer.floatChannelData![channel][frame] = 0.5 * sinf(2 * .pi * 440 * Float(frame) / 48_000)
        }
    }
    return buffer
}
