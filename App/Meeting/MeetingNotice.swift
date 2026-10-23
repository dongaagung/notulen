import Foundation

/// Something the owner should know while a meeting records. The recording
/// usually carries on.
enum MeetingNotice: Equatable, Identifiable {
    /// Nothing heard from the meeting audio since the start, which usually
    /// means the audio-capture permission was denied.
    case silent
    case error(String)
    /// Recording went on by itself after the Mac slept this long.
    case resumedAfterSleep(TimeInterval)
    /// The mic moved to the input device with this name.
    case micChanged(String)
    /// The meeting plays through the Mac's own speakers, so the mic hears
    /// the other participants too.
    case speakerOutput

    /// The meeting audio kept for speaker separation reached its 4-hour cap.
    static let speakerAudioFull = MeetingNotice.error(
        "Batas 4 jam audio untuk pemisahan pembicara tercapai. Sisa meeting tetap ditranskripsi dan berlabel Lainnya.")
    /// Meeting audio couldn't be converted for speaker separation.
    static let speakerAudioFailed = MeetingNotice.error("Audio meeting untuk pemisahan pembicara gagal diproses.")

    var id: String {
        switch self {
        case .silent: "silent"
        case .error(let message): "error:\(message)"
        case .resumedAfterSleep(let duration): "resumedAfterSleep:\(duration)"
        case .micChanged(let name): "micChanged:\(name)"
        case .speakerOutput: "speakerOutput"
        }
    }

    var message: String {
        switch self {
        case .silent:
            """
            Belum ada suara dari meeting. Kalau peserta sedang bicara, izinkan Notulen di \
            Pengaturan Sistem › Privasi & Keamanan › Perekaman Layar & Audio Sistem, lalu mulai lagi.
            """
        case .error(let message):
            message
        case .resumedAfterSleep(let duration):
            "Rekaman dilanjutkan setelah Mac tidur \(MeetingTime.duration(duration))."
        case .micChanged(let name):
            "Mic berganti ke \(name)."
        case .speakerOutput:
            "Suara meeting keluar lewat speaker Mac. Suara peserta lain bisa masuk ke mic dan terlabel “Saya”. Pakai headset."
        }
    }
}
