import Foundation

/// Something the owner should know while a meeting records. The recording
/// usually carries on.
enum MeetingNotice: Equatable, Identifiable {
    /// Nothing heard from the meeting audio since the start, which usually
    /// means the audio-capture permission was denied.
    case silent
    case error(String)

    var id: String {
        switch self {
        case .silent: "silent"
        case .error(let message): "error:\(message)"
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
        }
    }
}
