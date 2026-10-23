import Foundation

/// The minutes as one standalone HTML page for the PDF export: the same
/// sections, order and text as the Markdown, laid out like the app on A4.
/// All text is escaped; the CSS is inline.
enum MinutesHTML {
    static let none = "<p class=\"none\">Tidak ada.</p>"

    static func render(_ minutes: Minutes, meeting: Meeting, timeZone: TimeZone = .current) -> String {
        func text(_ text: String) -> String { escape(MinutesFormatting.oneLine(text, in: meeting)) }
        func time(_ label: String) -> String { "<span class=\"time\">\(escape(label))</span>" }
        func row(_ mark: String, _ body: String, at seconds: Double, done: Bool = false, box: Bool = false) -> String {
            "<div class=\"row\(done ? " done" : "")\"><span class=\"mark\(box ? " box" : "")\">\(mark)</span>"
                + "<div class=\"text\">\(body)</div>\(time(MeetingTime.format(seconds)))</div>"
        }
        func section(_ title: String, _ rows: [String]) -> [String] {
            ["<h2>\(title)</h2>"] + (rows.isEmpty ? [none] : ["<div class=\"card\">"] + rows + ["</div>"])
        }

        let title = escape(MinutesFormatting.title(minutes, meeting: meeting))
        var body = [
            "<p class=\"meta\">\(escape(MinutesFormatting.dateLine(meeting, timeZone: timeZone)))</p>",
            "<h1>\(title)</h1>",
            "<p class=\"people\">Peserta: \(escape(MinutesFormatting.participants(of: meeting).joined(separator: ", ")))</p>",
            "<h2>Ringkasan</h2>",
            MinutesFormatting.summary(minutes, in: meeting).map { "<p class=\"summary\">\(escape($0))</p>" } ?? none,
        ]
        body += section("Keputusan", minutes.decisions.map { row("◆", text($0.text), at: $0.at) })
        body += section("Action item", minutes.actionItems.map { item in
            let done = meeting.actionItemsDone.contains(item.id)
            let named = MinutesFormatting.ownerIsNamed(item, in: meeting)
            let owner = "<span class=\"owner\(named ? "" : " anon")\">\(escape(MinutesFormatting.owner(item, in: meeting)))</span>"
            let due = MinutesFormatting.due(item, in: meeting).map { " · \(escape($0))" } ?? ""
            return row(
                done ? "☑" : "☐", "<span class=\"task\">\(text(item.task))</span><span class=\"sub\">\(owner)\(due)</span>",
                at: item.at, done: done, box: true)
        })
        body += section("Pertanyaan terbuka", minutes.openQuestions.map { question in
            let context = MinutesFormatting.context(question, in: meeting).map { "<span class=\"sub\">\(escape($0))</span>" }
            return row("?", text(question.question) + (context ?? ""), at: question.at)
        })
        body.append("<h2>Topik yang dibahas</h2>")
        if minutes.topics.isEmpty { body.append(none) }
        for (index, topic) in minutes.topics.enumerated() {
            let span = "\(MeetingTime.format(topic.start))–\(MeetingTime.format(topic.end))"
            body.append("<div class=\"topic\">")
            body.append("<h3><span class=\"title\">\(index + 1). \(text(topic.title))</span>\(time(span))</h3>")
            if !topic.points.isEmpty {
                body += ["<ul>"] + topic.points.map { "<li>\(text($0))</li>" } + ["</ul>"]
            }
            body.append("</div>")
        }

        return """
            <!DOCTYPE html>
            <html lang="id">
            <head>
            <meta charset="utf-8">
            <title>\(title)</title>
            <style>
            \(style)
            </style>
            </head>
            <body>
            \(body.joined(separator: "\n"))
            </body>
            </html>

            """
    }

    /// Text safe inside an element or an attribute.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    /// The app's minutes page in print: system font, the same sizes, the
    /// times in blue, rows that don't split across pages.
    static let style = """
        @page { size: A4; margin: 18mm; }
        :root { --ink: #1D1D1F; --ink2: #6E6E73; --ink3: #A1A1A6; --line: #E3E3E6; --tint: #0A84FF; }
        * { box-sizing: border-box; }
        html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        /* WebKit clips a printed page about 1 px inside its right edge;
           the padding keeps the cards' right border on the page. */
        body { margin: 0; padding-right: 2px; color: var(--ink); font-size: 14px; line-height: 1.5;
               font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
        p { margin: 0; }
        .meta { font-size: 12px; color: var(--ink2); }
        h1 { font-size: 28px; line-height: 1.15; font-weight: 700; letter-spacing: -0.015em; margin: 6px 0 10px; }
        .people { font-size: 12px; color: var(--ink2); }
        h2 { font-size: 17px; font-weight: 700; margin: 28px 0 10px; break-after: avoid; page-break-after: avoid; }
        .summary { line-height: 1.6; white-space: pre-line; }
        .none { color: var(--ink2); }
        .card { border: 1px solid var(--line); border-radius: 12px; }
        .row { display: flex; align-items: baseline; gap: 10px; padding: 10px 14px; line-height: 1.45;
               break-inside: avoid; page-break-inside: avoid; }
        .row + .row { border-top: 1px solid var(--line); }
        .mark { flex: none; width: 18px; text-align: center; color: var(--ink3); }
        .box { font-size: 17px; line-height: 1; color: var(--ink2); }
        .done .box { color: var(--tint); }
        .text { flex: 1; min-width: 0; }
        .sub { display: block; font-size: 12px; color: var(--ink2); margin-top: 2px; }
        .owner { font-weight: 600; color: var(--ink); }
        .owner.anon { font-weight: 400; font-style: italic; color: var(--ink2); }
        .done .task { text-decoration: line-through; color: var(--ink2); }
        .done .owner { color: var(--ink2); }
        .time { flex: none; padding-left: 12px; font-size: 12px; font-weight: 400; color: var(--tint);
                font-variant-numeric: tabular-nums; white-space: nowrap; }
        .topic { margin-bottom: 16px; }
        h3 { display: flex; align-items: baseline; font-size: 15px; font-weight: 600; margin: 0 0 6px;
             break-after: avoid; page-break-after: avoid; }
        h3 .title { flex: 1; }
        ul { margin: 0; padding: 0; list-style: none; }
        li { position: relative; padding-left: 16px; margin-bottom: 4px; line-height: 1.55; break-inside: avoid; }
        li::before { content: ""; position: absolute; left: 2px; top: 0.66em; width: 5px; height: 5px; border-radius: 50%;
                     background: var(--ink3); }
        /* A trailing margin past the last line would start an empty page. */
        body > :last-child, li:last-child { margin-bottom: 0; }
        """
}
