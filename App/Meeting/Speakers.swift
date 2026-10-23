import Foundation

extension Meeting {
    /// Who said the line now: the user's reassignment if any, else the
    /// diarized speaker, then through any merges to the final speaker.
    func speaker(of line: TranscriptLine) -> SpeakerID {
        let assigned = speakerAssignments.last { $0.line == line.id }?.speaker ?? line.speaker
        return resolved(assigned)
    }

    /// Follows `from → to` merges to the end. A cycle stops at the first
    /// speaker seen twice, so this always returns.
    func resolved(_ id: SpeakerID) -> SpeakerID {
        var current = id
        var seen: Set<SpeakerID> = [id]
        while let next = merges.last(where: { $0.from == current })?.to, seen.insert(next).inserted {
            current = next
        }
        return current
    }

    func displayName(for id: SpeakerID) -> String {
        let id = resolved(id)
        if id == .me { return "Saya" }
        guard let number = id.remoteNumber, let info = speakers.first(where: { $0.id == id }) else {
            return "Lainnya"
        }
        let name = info.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Pembicara \(number)" : name
    }
}

/// AI text names speakers as [[s3]], [[me]], [[others]]; this swaps in the
/// current names, so renames and merges need no regeneration.
enum SpeakerTokens {
    static func render(_ text: String, name: (SpeakerID) -> String) -> String {
        text.replacing(/\[\[(me|others|s\d+)\]\]/) { match in name(SpeakerID(String(match.1))) }
    }
}
