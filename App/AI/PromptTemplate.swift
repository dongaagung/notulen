import Foundation

/// A `prompts/<name>.md` template with `{{variable}}` placeholders.
struct PromptTemplate: Sendable {
    enum Failure: LocalizedError, Equatable {
        case notFound(String)
        case missingVariables(template: String, names: [String])

        var errorDescription: String? {
            switch self {
            case .notFound(let name):
                "Prompt template prompts/\(name).md is missing from the app bundle."
            case .missingVariables(let template, let names):
                "Prompt \(template) needs values for: \(names.joined(separator: ", "))."
            }
        }
    }

    let name: String
    let text: String

    /// Looks in the app bundle's Resources/prompts, then ./prompts (for `swift run`).
    static func load(_ name: String, from directory: URL? = nil) throws -> PromptTemplate {
        let directories = [
            directory,
            Bundle.main.resourceURL?.appending(path: "prompts"),
            URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "prompts"),
        ].compactMap { $0 }
        for directory in directories {
            let url = directory.appending(path: "\(name).md")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return PromptTemplate(name: name, text: text)
            }
        }
        throw Failure.notFound(name)
    }

    var variableNames: Set<String> {
        Set(text.matches(of: Self.placeholder).map { String($0.output.1) })
    }

    /// Fills every placeholder. Throws if any placeholder has no value;
    /// extra values are ignored.
    func render(_ values: [String: String]) throws -> String {
        let missing = variableNames.subtracting(values.keys).sorted()
        guard missing.isEmpty else { throw Failure.missingVariables(template: name, names: missing) }
        return text
            .replacing(Self.placeholder) { values[String($0.output.1)] ?? "" }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var placeholder: Regex<(Substring, Substring)> {
        /\{\{\s*([A-Za-z0-9_]+)\s*\}\}/
    }
}
