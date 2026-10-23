/// One capture channel: the meeting app's audio or the owner's mic.
/// `MeetingSession` only sees this, so tests can hand it fakes.
@MainActor
protocol AudioCapturing: AnyObject {
    /// Starts capturing. The stream ends at `stop()`.
    func start() throws -> AsyncStream<AudioChunk>
    func stop()
}

/// The mic can be turned off mid-meeting without ending its stream.
@MainActor
protocol MicCapturing: AudioCapturing {
    /// Lets go of the mic, so the menu bar's mic indicator goes away. The
    /// stream stays open.
    func pause()
    /// Takes the mic again after `pause()`.
    func resume() throws
}

/// The two capture channels of one meeting.
struct CaptureDevices {
    var meeting: any AudioCapturing
    var mic: any MicCapturing

    @MainActor static func live(_ source: MeetingAudioSource) -> CaptureDevices {
        CaptureDevices(meeting: ProcessTapCapture(source: source), mic: MicCapture())
    }
}
