import Foundation

/// Wording shared by the Markdown, PDF and Notion exports.
enum MinutesFormatting {
    /// "Kamis, 22 Oktober 2026 · 09.00–10.12 · 1 jam 12 menit · Bahasa
    /// Indonesia"; just the start time while the meeting has no end.
    static func dateLine(_ meeting: Meeting, timeZone: TimeZone = .current) -> String {
        let locale = Locale(identifier: "id_ID")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = Date.FormatStyle(date: .complete, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone)
        // "09.00": the locale's short time drops the leading zero.
        let time = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        var parts = [meeting.startedAt.formatted(day)]
        if let end = meeting.endedAt {
            parts.append("\(meeting.startedAt.formatted(time))–\(end.formatted(time))")
            parts.append(duration(end.timeIntervalSince(meeting.startedAt)))
        } else {
            parts.append(meeting.startedAt.formatted(time))
        }
        parts.append(languageName(meeting.language))
        return parts.joined(separator: " · ")
    }

    /// "Bahasa Indonesia" for "id-ID", "Bahasa Inggris" for "en-US".
    static func languageName(_ bcp47: String) -> String {
        guard let code = Locale(identifier: bcp47).language.languageCode?.identifier,
              let name = Locale(identifier: "id_ID").localizedString(forLanguageCode: code)
        else { return bcp47 }
        return "Bahasa \(name)"
    }

    /// "1 jam 12 menit", "45 menit".
    static func duration(_ seconds: TimeInterval) -> String {
        MeetingTime.duration(seconds)
    }

    /// The speaker's name once they have one, else the name the AI heard,
    /// else "Pembicara N"; "pemegang tidak disebut" when nobody was named.
    static func owner(_ item: Minutes.ActionItem, in meeting: Meeting) -> String {
        let heard = item.owner?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let speaker = item.owner?.speaker {
            if meeting.hasName(speaker) || heard.isEmpty { return meeting.displayName(for: speaker) }
            return heard
        }
        return heard.isEmpty ? "pemegang tidak disebut" : heard
    }

    /// The owner, then the remote speakers in order, merged ones once.
    static func participants(of meeting: Meeting) -> [String] {
        var seen: Set<SpeakerID> = [.me]
        var names = [meeting.displayName(for: .me)]
        for info in meeting.speakers {
            let id = meeting.resolved(info.id)
            if seen.insert(id).inserted { names.append(meeting.displayName(for: id)) }
        }
        return names
    }
}
