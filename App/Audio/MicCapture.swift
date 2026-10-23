import AVFoundation
import CoreAudio

/// Captures the owner's microphone with AVAudioEngine, from the system's
/// default input device. When that device changes (a headset plugged in or
/// out mid-meeting) or its format changes, the engine restarts on the new
/// device and the stream carries on.
@MainActor
final class MicCapture: MicCapturing {
    enum Failure: LocalizedError {
        case permissionDenied
        case noInputDevice

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "Akses mikrofon mati. Nyalakan di Pengaturan Sistem › Privasi & Keamanan › Mikrofon."
            case .noInputDevice:
                "Mikrofon tidak ditemukan."
            }
        }
    }

    /// Called with the input device's name after the mic moved to another device.
    var onDeviceChange: (@MainActor (String) -> Void)?
    /// Called with the last error when every restart attempt after a device
    /// change failed. The mic stays silent until the next device change, or
    /// until it's turned off and on.
    var onRestartFailure: (@MainActor (any Error) -> Void)?

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var isPaused = false
    /// The default input when the engine last started; `.unknown` while
    /// stopped or paused.
    private var attachedDevice = AudioObjectID.unknown
    /// The device the owner last heard about: the one capture started on, or
    /// the last one `onDeviceChange` reported.
    private var announcedDevice = AudioObjectID.unknown
    private var inputListener: AudioObjectPropertyListenerBlock?
    private var configurationObserver: (any NSObjectProtocol)?
    private var restartTask: Task<Void, Never>?

    /// One headset switch fires both the default-input listener and the
    /// engine's configuration change; restart once, after they settle.
    private static let restartDelay = Duration.milliseconds(300)
    /// A headset that is still connecting can refuse to start. After this many
    /// tries, the next device change (or turning the mic off and on) restarts it.
    private static let restartAttempts = 3

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws -> AsyncStream<AudioChunk> {
        stop()
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioChunk.self, bufferingPolicy: .bufferingNewest(128))
        do {
            try attach(continuation)
        } catch {
            continuation.finish()
            throw error
        }
        self.continuation = continuation
        announcedDevice = attachedDevice
        listenForDeviceChanges()
        return stream
    }

    func stop() {
        stopListeningForDeviceChanges()
        restartTask?.cancel()
        restartTask = nil
        guard let continuation else { return }
        detach()
        continuation.finish()
        self.continuation = nil
        isPaused = false
        announcedDevice = .unknown
    }

    /// Stops the engine, so the menu bar's mic indicator goes away. The stream
    /// stays open, and device changes are ignored until `resume()`.
    func pause() {
        guard continuation != nil, !isPaused else { return }
        isPaused = true
        restartTask?.cancel()
        restartTask = nil
        detach()
    }

    /// Taps the current default input again, which may be a different device
    /// than before `pause()`.
    func resume() throws {
        guard let continuation, isPaused else { return }
        try attach(continuation)
        isPaused = false
        announceDeviceIfChanged()
    }

    /// Taps the input node in the hardware's current format and starts the
    /// engine. Every tap feeds the same continuation, so the stream outlives
    /// restarts.
    ///
    /// The engine doesn't open the default input device itself but a private
    /// aggregate (CADefaultDeviceAggregate) of the default input and output
    /// devices, which follows the defaults on its own. So a restart lands on
    /// the new default input, and an output-only change (headphones) also
    /// stops the engine with a configuration change.
    private func attach(_ continuation: AsyncStream<AudioChunk>.Continuation) throws {
        let device = try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID.unknown)
        guard device.isValid else { throw Failure.noInputDevice }
        let input = engine.inputNode
        // From the hardware format, not the node's output format: after a
        // configuration change the node keeps the format the last tap set, and
        // a tap whose sample rate differs from the hardware's raises an exception.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount)
        else { throw Failure.noInputDevice }

        // @Sendable keeps the tap block off the main actor: it runs on the audio thread.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            if let copy = buffer.copied() {
                continuation.yield(AudioChunk(buffer: copy))
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        attachedDevice = device
    }

    /// Releases the tap and the engine. The continuation stays open.
    private func detach() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        attachedDevice = .unknown
    }

    private func listenForDeviceChanges() {
        let listener: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            // Registered on the main queue.
            MainActor.assumeIsolated { self?.scheduleRestart(after: Self.restartDelay, attempt: 1) }
        }
        var address = AudioObjectPropertyAddress(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(.system, &address, .main, listener)
        inputListener = listener

        // The engine stops itself when its hardware's sample rate or channel
        // count changes, then posts this on an internal queue.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            // Only hop to the main actor here: tearing the engine down inside
            // this handler can deadlock.
            Task { @MainActor in self?.scheduleRestart(after: Self.restartDelay, attempt: 1) }
        }
    }

    private func stopListeningForDeviceChanges() {
        if let inputListener {
            var address = AudioObjectPropertyAddress(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(.system, &address, .main, inputListener)
            self.inputListener = nil
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    /// Debounced: a newer event replaces a restart that hasn't run yet.
    private func scheduleRestart(after delay: Duration, attempt: Int) {
        guard continuation != nil, !isPaused else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.restart(attempt: attempt)
        }
    }

    /// Releases the tap, stops the engine, then taps the (possibly new)
    /// default input in its new format and starts again.
    private func restart(attempt: Int) {
        guard let continuation, !isPaused else { return }
        detach()
        do {
            try attach(continuation)
        } catch {
            if attempt < Self.restartAttempts {
                scheduleRestart(after: .seconds(1), attempt: attempt + 1)
            } else {
                onRestartFailure?(error)
            }
            return
        }
        announceDeviceIfChanged()
    }

    private func announceDeviceIfChanged() {
        guard attachedDevice != announcedDevice else { return }
        announcedDevice = attachedDevice
        let name = (try? attachedDevice.readString(kAudioObjectPropertyName)) ?? "mikrofon lain"
        onDeviceChange?(name)
    }
}
