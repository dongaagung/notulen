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

    /// The name the owner gave; empty or blank clears it.
    mutating func rename(_ id: SpeakerID, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if let index = speakers.firstIndex(where: { $0.id == id }) {
            speakers[index].name = value
        } else {
            speakers.append(SpeakerInfo(id: id, name: value))
        }
    }

    /// Counts everything `from` said as `to`. Ignored for itself and for a
    /// merge that would loop back.
    mutating func merge(_ from: SpeakerID, into to: SpeakerID) {
        guard from != to, resolved(to) != from else { return }
        merges.append(SpeakerMerge(from: from, to: to))
    }

    /// Speakers in `candidates` that `id` can be merged into: not itself
    /// (after merges), none twice, none that would loop.
    func mergeTargets(for id: SpeakerID, among candidates: [SpeakerID]) -> [SpeakerID] {
        var seen: Set<SpeakerID> = [resolved(id)]
        return candidates.map { resolved($0) }.filter { target in
            resolved(target) != id && seen.insert(target).inserted
        }
    }

    /// The longest lines the speaker said, in time order.
    func sampleLines(for id: SpeakerID, in lines: [TranscriptLine], count: Int = 3) -> [TranscriptLine] {
        let target = resolved(id)
        let longest = lines.filter { speaker(of: $0) == target }
            .sorted { $0.text.count > $1.text.count }
            .prefix(max(count, 0))
        return longest.sorted { $0.start < $1.start }
    }

    /// AI text with the speakers' current names in place of their tokens.
    func named(_ text: String) -> String {
        SpeakerTokens.render(text) { displayName(for: $0) }
    }

    /// The owner always has a name; a remote speaker once renamed.
    func hasName(_ id: SpeakerID) -> Bool {
        let id = resolved(id)
        if id == .me { return true }
        guard id.remoteNumber != nil else { return false }
        let name = speakers.first { $0.id == id }?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !name.isEmpty
    }
}

/// AI text names speakers as [[s3]], [[me]], [[others]]; this swaps in the
/// current names, so renames and merges need no regeneration.
enum SpeakerTokens {
    static func render(_ text: String, name: (SpeakerID) -> String) -> String {
        text.replacing(/\[\[(me|others|s\d+)\]\]/) { match in name(SpeakerID(String(match.1))) }
    }
}
