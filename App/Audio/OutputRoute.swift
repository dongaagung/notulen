import CoreAudio

/// Where the meeting's sound comes out. Through the Mac's own speakers, the
/// other participants' voices reach the mic and get labeled "Saya".
enum OutputRoute {
    /// 'ispk', `kIOAudioOutputPortSubTypeInternalSpeaker` in IOKit/audio/IOAudioTypes.h.
    private static let internalSpeaker: UInt32 = 0x6973_706B

    /// True only when the default output plays through the internal speakers.
    static func isBuiltInSpeaker() -> Bool {
        guard let device = try? AudioObjectID.system.read(
                  kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID.unknown),
              device.isValid,
              let transport = try? device.read(kAudioDevicePropertyTransportType, initial: UInt32(0)),
              let dataSource = try? device.read(
                  kAudioDevicePropertyDataSource, initial: UInt32(0), scope: kAudioObjectPropertyScopeOutput)
        else { return false }
        return isBuiltInSpeaker(transportType: transport, dataSource: dataSource)
    }

    /// The built-in output also reports a built-in transport when headphones
    /// are plugged into the Mac's jack, so the data source decides: 'ispk' is
    /// the internal speaker, 'hdpn' headphones.
    static func isBuiltInSpeaker(transportType: UInt32, dataSource: UInt32) -> Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn && dataSource == internalSpeaker
    }
}
