import Foundation

/// A transcript as it reads: its lines, with a divider where the recording
/// broke off ("Rekaman terputus 42:10–58:30 (Mac tidur)") and where the
/// owner's mic was off ("Mic mati 12:00–15:30"), all in time order.
enum TranscriptRows {
    enum Row: Identifiable, Equatable {
        case line(TranscriptLine)
        /// The meeting's `index`th gap.
        case gap(index: Int, Gap)
        /// The meeting's `index`th mic-off period.
        case micOff(index: Int, TimeSpan)

        enum ID: Hashable {
            case line(TranscriptLine.ID), gap(Int), micOff(Int)
        }

        var id: ID {
            switch self {
            case .line(let line): .line(line.id)
            case .gap(let index, _): .gap(index)
            case .micOff(let index, _): .micOff(index)
            }
        }

        /// Meeting time the row starts at.
        var time: TimeInterval {
            switch self {
            case .line(let line): line.start
            case .gap(_, let gap): gap.span.start
            case .micOff(_, let span): span.start
            }
        }

        /// What a divider says; nil for a line.
        var dividerText: String? {
            switch self {
            case .line: nil
            case .gap(_, let gap): TranscriptRows.text(for: gap)
            case .micOff(_, let span): TranscriptRows.text(forMicOff: span)
            }
        }

        fileprivate var isDivider: Bool {
            if case .line = self { false } else { true }
        }
    }

    /// The lines and dividers by when they start; a divider comes before a
    /// line that starts at the same time. The journal can be slightly out
    /// of order, so the lines are sorted too.
    static func build(lines: [TranscriptLine], gaps: [Gap], micOff: [TimeSpan]) -> [Row] {
        let rows = lines.map(Row.line) + dividers(gaps: gaps, micOff: micOff)
        return rows.enumerated().sorted { a, b in
            if a.element.time != b.element.time { return a.element.time < b.element.time }
            if a.element.isDivider != b.element.isDivider { return a.element.isDivider }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The gaps and mic-off periods on one line, in time order, for under
    /// the minutes' meta line; nil when there are none.
    static func summary(gaps: [Gap], micOff: [TimeSpan]) -> String? {
        let texts = build(lines: [], gaps: gaps, micOff: micOff).compactMap(\.dividerText)
        return texts.isEmpty ? nil : texts.joined(separator: " · ")
    }

    /// "Rekaman terputus 42:10–58:30 (Mac tidur)".
    static func text(for gap: Gap) -> String {
        "Rekaman terputus \(TranscriptFormatter.span(gap.span)) (\(TranscriptFormatter.reason(gap.reason)))"
    }

    /// "Mic mati 12:00–15:30".
    static func text(forMicOff span: TimeSpan) -> String {
        "Mic mati \(TranscriptFormatter.span(span))"
    }

    private static func dividers(gaps: [Gap], micOff: [TimeSpan]) -> [Row] {
        gaps.enumerated().map { Row.gap(index: $0.offset, $0.element) }
            + micOff.enumerated().map { Row.micOff(index: $0.offset, $0.element) }
    }
}
