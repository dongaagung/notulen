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

/// Tells when the meeting's sound may have moved to or from the Mac's
/// speakers. `MeetingSession` only sees this, so tests can hand it a fake.
@MainActor
protocol OutputRouteMonitoring: AnyObject {
    /// Called on the main actor after the route may have changed.
    var onChange: (@MainActor () -> Void)? { get set }
    /// True while the default output plays through the Mac's own speakers.
    var isBuiltInSpeaker: Bool { get }
    func start()
    func stop()
}

/// Watches the default output device, and that device's data source:
/// headphones in the Mac's jack switch the built-in output from 'ispk' to
/// 'hdpn' on the same device, so the device alone can't tell. The tap's
/// own output listener misses both: it follows the sound-effects device.
@MainActor
final class OutputRouteMonitor: OutputRouteMonitoring {
    var onChange: (@MainActor () -> Void)?

    var isBuiltInSpeaker: Bool { OutputRoute.isBuiltInSpeaker() }

    private var outputListener: AudioObjectPropertyListenerBlock?
    private var dataSourceListener: AudioObjectPropertyListenerBlock?
    /// The device `dataSourceListener` listens to.
    private var dataSourceDevice = AudioObjectID.unknown

    private static var dataSourceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
    }

    func start() {
        stop()
        let listener: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            // Registered on the main queue.
            MainActor.assumeIsolated { self?.defaultOutputChanged() }
        }
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(.system, &address, .main, listener)
        outputListener = listener
        listenToDataSource()
    }

    func stop() {
        if let outputListener {
            var address = AudioObjectPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(.system, &address, .main, outputListener)
            self.outputListener = nil
        }
        stopListeningToDataSource()
    }

    /// The data-source listener moves to the new default output device.
    private func defaultOutputChanged() {
        // A change queued before `stop()` comes too late.
        guard outputListener != nil else { return }
        listenToDataSource()
        onChange?()
    }

    /// Most USB and Bluetooth devices have no data source to listen to.
    private func listenToDataSource() {
        stopListeningToDataSource()
        var address = Self.dataSourceAddress
        guard let device = try? AudioObjectID.system.read(
                  kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID.unknown),
              device.isValid, AudioObjectHasProperty(device, &address)
        else { return }
        let listener: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            // Registered on the main queue.
            MainActor.assumeIsolated { self?.dataSourceChanged() }
        }
        guard AudioObjectAddPropertyListenerBlock(device, &address, .main, listener) == noErr else { return }
        dataSourceListener = listener
        dataSourceDevice = device
    }

    private func dataSourceChanged() {
        // A change queued before `stop()` comes too late.
        guard outputListener != nil else { return }
        onChange?()
    }

    /// The old device may be gone already (AirPods taken out); removing
    /// then fails harmlessly.
    private func stopListeningToDataSource() {
        if let dataSourceListener {
            var address = Self.dataSourceAddress
            AudioObjectRemovePropertyListenerBlock(dataSourceDevice, &address, .main, dataSourceListener)
            self.dataSourceListener = nil
        }
        dataSourceDevice = .unknown
    }
}
