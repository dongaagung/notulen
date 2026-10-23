import Foundation

/// Writes minutes pages through the Notion API with an internal-integration
/// token: creates a page under the owner's parent page, or replaces the
/// content of the page made earlier.
struct NotionClient {
    static let version = "2026-03-11"
    static let baseURL = "https://api.notion.com"
    /// Notion's limit for a children array.
    static let batchSize = 100
    static let maxRetries = 3

    enum Failure: LocalizedError, Equatable {
        /// 404: the page doesn't exist or isn't shared with the integration.
        case pageNotShared
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .pageNotShared:
                "Halaman Notion tidak ditemukan. Pastikan halaman sudah dibagikan ke integrasi lewat Connections."
            case .http(let status, let message):
                message.isEmpty ? "Notion menjawab dengan kesalahan \(status)." : "Notion menolak permintaan (\(status)): \(message)"
            }
        }
    }

    let token: String
    let session: URLSession
    /// Waits `seconds`; tests replace it so retries take no time.
    let sleep: @Sendable (TimeInterval) async throws -> Void

    init(
        token: String, session: URLSession = .shared,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.token = token
        self.session = session
        self.sleep = sleep
    }

    func urlRequest(_ method: String, _ path: String, body: JSONValue?) throws -> URLRequest {
        guard let url = URL(string: Self.baseURL + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.version, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        return request
    }

    /// Creates the page under `parent`; the first 100 blocks go with it, the
    /// rest are appended. Returns the new page's ID.
    func createPage(parent: String, title: String, children: [JSONValue]) async throws -> String {
        let body: JSONValue = [
            "parent": ["type": "page_id", "page_id": .string(parent)],
            "properties": Self.titleProperties(title),
            "children": .array(Array(children.prefix(Self.batchSize))),
        ]
        let data: Data
        do {
            data = try await send("POST", "/v1/pages", body: body)
        } catch Failure.http(404, _) {
            throw Failure.pageNotShared
        }
        guard let id = Self.object(data)?["id"] as? String else { throw Failure.http(200, "Jawaban Notion tidak berisi ID halaman.") }
        try await append(Array(children.dropFirst(Self.batchSize)), to: id)
        return id
    }

    /// Sets the title, deletes the page's blocks, then appends `children`.
    /// Throws `.pageNotShared` when the page can't be found.
    func replaceContent(of page: String, title: String, with children: [JSONValue]) async throws {
        do {
            try await send("PATCH", "/v1/pages/\(page)", body: ["properties": Self.titleProperties(title)])
            for id in try await childIDs(of: page) {
                do {
                    try await send("DELETE", "/v1/blocks/\(id)", body: nil)
                } catch Failure.http(404, _) {
                    continue  // gone already
                }
            }
        } catch Failure.http(404, _) {
            throw Failure.pageNotShared
        }
        try await append(children, to: page)
    }

    /// Creates the minutes' page, or rewrites `existing` when there is one.
    /// A stored page that's gone (deleted in Notion) gets a new page under
    /// `parent`. Returns the page's ID, to store.
    func publish(existing: String?, parent: String, title: String, children: [JSONValue]) async throws -> String {
        if let existing {
            do {
                try await replaceContent(of: existing, title: title, with: children)
                return existing
            } catch Failure.pageNotShared {
                // Falls through to a new page; a parent that can't be found
                // either throws from there.
            }
        }
        return try await createPage(parent: parent, title: title, children: children)
    }

    // MARK: Requests

    private static func titleProperties(_ title: String) -> JSONValue {
        ["title": ["title": NotionBlocks.richText(title)]]
    }

    private func append(_ children: [JSONValue], to id: String) async throws {
        for start in stride(from: 0, to: children.count, by: Self.batchSize) {
            let batch = Array(children[start..<min(start + Self.batchSize, children.count)])
            try await send(
                "PATCH", "/v1/blocks/\(id)/children",
                body: ["children": .array(batch), "position": ["type": "end"]])
        }
    }

    /// The IDs of all the block's children, over as many pages as it takes.
    private func childIDs(of id: String) async throws -> [String] {
        var ids: [String] = []
        var cursor: String?
        repeat {
            var path = "/v1/blocks/\(id)/children?page_size=\(Self.batchSize)"
            if let cursor { path += "&start_cursor=\(cursor)" }
            let data = try await send("GET", path, body: nil)
            guard let object = Self.object(data) else { break }
            ids += (object["results"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            cursor = object["has_more"] as? Bool == true ? object["next_cursor"] as? String : nil
        } while cursor != nil
        return ids
    }

    /// Sends the request; after a 429, waits as long as Retry-After says
    /// (1 s without it) and tries again, up to 3 times.
    @discardableResult
    private func send(_ method: String, _ path: String, body: JSONValue?) async throws -> Data {
        let request = try urlRequest(method, path, body: body)
        var retries = 0
        while true {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return data }
            if status == 429, retries < Self.maxRetries {
                retries += 1
                let wait = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                try await sleep(wait ?? 1)
                continue
            }
            throw Failure.http(status, Self.message(in: data))
        }
    }

    private static func message(in data: Data) -> String {
        object(data)?["message"] as? String ?? ""
    }

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
