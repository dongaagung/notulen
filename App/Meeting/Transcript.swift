import Foundation

/// Captions for both channels: finalized lines plus each channel's
/// in-progress (volatile) text.
struct Transcript: Equatable {
    private(set) var lines: [TranscriptLine]
    private(set) var volatileText: [Channel: String] = [:]

    init(lines: [TranscriptLine] = []) {
        self.lines = lines
    }

    /// Applies one recognizer update. Returns the line it finalized, if any.
    /// `offset`: meeting time at which this channel's current audio stream
    /// started. `now`: meeting time now.
    @discardableResult
    mutating func apply(
        _ update: TranscriptUpdate, channel: Channel, offset: TimeInterval, now: TimeInterval
    ) -> TranscriptLine? {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard update.isFinal else {
            volatileText[channel] = text.isEmpty ? nil : text
            return nil
        }
        volatileText[channel] = nil
        guard !text.isEmpty else { return nil }
        let start = update.span.map { offset + $0.start } ?? now
        let end = update.span.map { offset + $0.end } ?? now
        // A final that is only punctuation ("?") belongs to the channel's last line.
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
            if let index = lines.indices.last, lines[index].channel == channel,
               lines[index].text.last.map({ !".?!".contains($0) }) ?? false {
                lines[index].text += text
                lines[index].end = max(lines[index].end, end)
            }
            return nil
        }
        let line = TranscriptLine(
            channel: channel, speaker: channel == .mic ? .me : .others, text: text, start: start, end: end)
        lines.append(line)
        return line
    }

    mutating func discardVolatile(_ channel: Channel) {
        volatileText[channel] = nil
    }
}

/// Without headphones the mic also hears the meeting through the speakers.
/// Drops "my" lines that repeat what the others just said.
enum EchoFilter {
    static func isLikelyEcho(_ text: String, at time: TimeInterval, recent lines: [TranscriptLine]) -> Bool {
        let words = Self.words(text)
        guard words.count >= 4 else { return false }
        let heard = Set(lines.suffix(6)
            .filter { $0.speaker == .others && abs($0.start - time) < 4 }
            .flatMap { Self.words($0.text) })
        guard !heard.isEmpty else { return false }
        let overlap = words.filter(heard.contains).count
        return Double(overlap) / Double(words.count) >= 0.8
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
