import Foundation

/// Reads a Notion page ID from what the owner pastes: a page URL, a dashed
/// UUID or the bare 32 hex digits.
enum NotionPageID {
    // NSRegularExpression: Swift's Regex has no lookbehind.
    private static let dashed = try! NSRegularExpression(
        pattern: "(?<![0-9a-fA-F-])[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![0-9a-fA-F-])")
    private static let bare = try! NSRegularExpression(pattern: "(?<![0-9a-fA-F])[0-9a-fA-F]{32}(?![0-9a-fA-F])")

    private static func lastMatch(of expression: NSRegularExpression, in text: String) -> String? {
        let all = NSRange(text.startIndex..., in: text)
        guard let range = expression.matches(in: text, range: all).last?.range, let swift = Range(range, in: text)
        else { return nil }
        return String(text[swift])
    }

    /// The last ID in the text's path (a URL's query and fragment don't
    /// count), lowercase as 8-4-4-4-12; nil when there is none.
    static func parse(_ input: String) -> String? {
        var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<end]) }
        if let match = lastMatch(of: dashed, in: path) { return match.lowercased() }
        guard let match = lastMatch(of: bare, in: path) else { return nil }
        let hex = match.lowercased()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range -> String in
            let start = hex.index(hex.startIndex, offsetBy: range.lowerBound)
            let end = hex.index(hex.startIndex, offsetBy: range.upperBound)
            return String(hex[start..<end])
        }
        return parts.joined(separator: "-")
    }
}
