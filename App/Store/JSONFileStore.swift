import Foundation

/// Reads and writes Codable values as JSON files under one directory.
struct JSONFileStore: Sendable {
    let directory: URL

    static func applicationSupport() throws -> JSONFileStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return JSONFileStore(directory: base.appending(path: "rakyat.notulen"))
    }

    /// Returns nil when the file doesn't exist yet.
    func load<T: Decodable>(_ type: T.Type, from path: String) throws -> T? {
        let url = directory.appending(path: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Self.decoder.decode(T.self, from: Data(contentsOf: url))
    }

    func save<T: Encodable>(_ value: T, to path: String) throws {
        let url = directory.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: url, options: .atomic)
    }

    /// Removes a file or a whole folder.
    func remove(_ path: String) throws {
        let url = directory.appending(path: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// File names (not paths) of the JSON files in a subdirectory.
    func list(_ subdirectory: String) -> [String] {
        let url = directory.appending(path: subdirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted()
    }

    /// Names of the folders directly inside a subdirectory.
    func subdirectories(_ subdirectory: String) -> [String] {
        let url = directory.appending(path: subdirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.appending(path: $0).path, isDirectory: &isDirectory)
            return isDirectory.boolValue
        }.sorted()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Compact single-line encoder (same dates and key order) for JSONL files.
    static let lineEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
