import Foundation

/// What a meeting does when the Mac wakes mid-recording. A short sleep
/// records on by itself; after a long one the owner is asked first, so a
/// forgotten Selesai doesn't add the next day's audio to this meeting.
enum WakePolicy {
    static let resumeLimit: TimeInterval = 15 * 60

    enum Decision: Equatable {
        case resume, ask
    }

    static func decision(sleptFor: TimeInterval) -> Decision {
        sleptFor <= resumeLimit ? .resume : .ask
    }
}
