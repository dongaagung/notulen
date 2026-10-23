import Foundation
import Synchronization
import Testing
@testable import Notulen

private let host = "api.notion.com"
private let start = Date(timeIntervalSince1970: 1_792_634_400)

private func meeting(done: Set<String> = ["a1"]) -> Meeting {
    Meeting(
        title: "Weekly Sync", startedAt: start, endedAt: start.addingTimeInterval(4320),
        status: .ready, language: "id-ID", audioSource: .systemWide,
        speakers: [SpeakerInfo(id: .remote(1), name: "Andi")], actionItemsDone: done)
}

private let minutes = Minutes(
    titleSuggestion: "Saran", summary: "[[s1]] melapor.",
    decisions: [Minutes.Decision(id: "d1", text: "Rilis diundur.", at: 14)],
    actionItems: [
        Minutes.ActionItem(id: "a1", task: "Kirim laporan", owner: .init(speaker: .remote(1), name: nil), due: "Jumat", at: 16),
        Minutes.ActionItem(id: "a2", task: "Cek anggaran", owner: nil, due: nil, at: 66),
    ],
    openQuestions: [Minutes.OpenQuestion(id: "q1", question: "Anggaran?", context: "Pemakaian naik.", at: 52)],
    topics: [Minutes.Topic(title: "Status", start: 2, end: 24, points: ["Fitur selesai."])])

private func type(_ block: JSONValue) -> String {
    guard case .object(let object) = block, case .string(let type)? = object["type"] else { return "" }
    return type
}

private func richText(_ block: JSONValue) -> [JSONValue] {
    guard case .object(let object) = block, case .string(let type)? = object["type"],
          case .object(let inner)? = object[type], case .array(let text)? = inner["rich_text"]
    else { return [] }
    return text
}

private func content(_ part: JSONValue) -> String {
    guard case .object(let object) = part, case .object(let text)? = object["text"],
          case .string(let content)? = text["content"]
    else { return "" }
    return content
}

private func plain(_ block: JSONValue) -> String { richText(block).map(content).joined() }

private func blocks(_ count: Int) -> [JSONValue] {
    (0..<count).map { NotionBlocks.paragraph("Baris \($0)") }
}

struct NotionPageIDTests {
    @Test func parsesPageIDFromURL() {
        #expect(NotionPageID.parse("https://www.notion.so/team/Notulen-Rapat-1429989fe8ac4effbc8f57f56486db54?pvs=4") == "1429989f-e8ac-4eff-bc8f-57f56486db54")
        #expect(NotionPageID.parse("1429989f-e8ac-4eff-bc8f-57f56486db54") == "1429989f-e8ac-4eff-bc8f-57f56486db54")
        #expect(NotionPageID.parse("halo") == nil)
    }

    @Test func acceptsBareHexUppercaseAndPadding() {
        let expected = "1429989f-e8ac-4eff-bc8f-57f56486db54"
        #expect(NotionPageID.parse("  1429989FE8AC4EFFBC8F57F56486DB54\n") == expected)
        #expect(NotionPageID.parse("1429989F-E8AC-4EFF-BC8F-57F56486DB54") == expected)
        #expect(NotionPageID.parse("https://notion.so/1429989fe8ac4effbc8f57f56486db54#section") == expected)
    }

    @Test func ignoresIDsInQueryAndTooLongRuns() {
        #expect(NotionPageID.parse("https://notion.so/Halaman?p=1429989fe8ac4effbc8f57f56486db54") == nil)
        #expect(NotionPageID.parse("1429989fe8ac4effbc8f57f56486db54aa") == nil)
        #expect(NotionPageID.parse("") == nil)
    }

    @Test func lastRunWinsInPath() {
        let url = "https://notion.so/aaaaaaaabbbbccccddddeeeeeeeeeeee/Judul-1429989fe8ac4effbc8f57f56486db54"
        #expect(NotionPageID.parse(url) == "1429989f-e8ac-4eff-bc8f-57f56486db54")
    }
}

struct NotionBlocksTests {
    @Test func actionItemsBecomeToDos() throws {
        let all = NotionBlocks.blocks(for: minutes, meeting: meeting())
        let todos = all.filter { type($0) == "to_do" }
        #expect(todos.count == 2)
        func checked(_ block: JSONValue) -> Bool? {
            guard case .object(let o) = block, case .object(let inner)? = o["to_do"], case .bool(let c)? = inner["checked"] else { return nil }
            return c
        }
        #expect(checked(todos[0]) == true)
        #expect(checked(todos[1]) == false)
        #expect(plain(todos[0]) == "Kirim laporan — Andi · Jumat (00:16)")
        #expect(plain(todos[1]) == "Cek anggaran — pemegang tidak disebut (01:06)")
    }

    @Test func blocksFollowTheMarkdownOrder() {
        let all = NotionBlocks.blocks(for: minutes, meeting: meeting())
        let headings = all.filter { type($0).hasPrefix("heading") }.map(plain)
        #expect(headings == ["Ringkasan", "Keputusan", "Action item", "Pertanyaan terbuka", "Topik yang dibahas", "1. Status (00:02–00:24)"])
        #expect(type(all[0]) == "paragraph")
        #expect(plain(all[1]) == "Peserta: Saya, Andi")
        #expect(plain(all[3]) == "Andi melapor.")
        #expect(plain(all[5]) == "Rilis diundur. (00:14)")
        #expect(type(all[5]) == "bulleted_list_item")
    }

    @Test func openQuestionContextContinuesTheItem() {
        let all = NotionBlocks.blocks(for: minutes, meeting: meeting())
        #expect(all.map(plain).contains("Anggaran? (00:52)\nPemakaian naik."))
    }

    @Test func emptySectionsSayNone() {
        let empty = Minutes(titleSuggestion: "", summary: "")
        let all = NotionBlocks.blocks(for: empty, meeting: meeting())
        #expect(all.filter { plain($0) == "Tidak ada." }.count == 5)
    }

    @Test func longTextIsSplit() {
        let long = Minutes(titleSuggestion: "", summary: String(repeating: "a", count: 4500))
        let all = NotionBlocks.blocks(for: long, meeting: meeting())
        let summary = all.first { type($0) == "paragraph" && richText($0).count > 1 }
        let parts = summary.map(richText) ?? []
        #expect(parts.count == 3)
        #expect(parts.map { content($0).count } == [2000, 2000, 500])
    }

    @Test func richTextOverTheArrayLimitContinuesInNewBlocks() {
        let text = String(repeating: "a", count: NotionBlocks.maxTextLength * 250)
        let long = Minutes(titleSuggestion: "", summary: text)
        let all = NotionBlocks.blocks(for: long, meeting: meeting())
        let paragraphs = all.filter { type($0) == "paragraph" }.dropFirst(2).prefix(3)
        #expect(paragraphs.map { richText($0).count } == [100, 100, 50])
        #expect(paragraphs.map(plain).joined() == text)
    }

    @Test func richTextKeepsMultibyteTextWithinTheLimit() {
        let parts = (NotionBlocks.richText(String(repeating: "😀", count: 1500)).arrayValue)
        #expect(parts.count == 2)
        #expect(parts.allSatisfy { content($0).utf16.count <= 2000 })
        #expect(NotionBlocks.richText("").arrayValue.isEmpty)
    }
}

private extension JSONValue {
    var arrayValue: [JSONValue] {
        if case .array(let items) = self { return items }
        return []
    }
}

final class Counter: Sendable {
    private let value = Mutex(0)
    func next() -> Int { value.withLock { $0 += 1; return $0 } }
}

final class Sleeps: Sendable {
    let values = Mutex<[TimeInterval]>([])
}

@Suite(.serialized)
struct NotionClientTests {
    let pageID = "1429989f-e8ac-4eff-bc8f-57f56486db54"
    let sleeps = Sleeps()

    func client() -> NotionClient {
        NotionClient(token: "t", session: StubURLProtocol.session) { seconds in
            sleeps.values.withLock { $0.append(seconds) }
        }
    }

    @Test func requestHeaders() throws {
        let request = try client().urlRequest("POST", "/v1/pages", body: ["a": 1])
        #expect(request.value(forHTTPHeaderField: "Notion-Version") == "2026-03-11")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.url?.absoluteString == "https://api.notion.com/v1/pages")
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody != nil)
        #expect(try client().urlRequest("GET", "/v1/x", body: nil).httpBody == nil)
    }

    @Test func notFoundParentMeansNotShared() async {
        StubURLProtocol.handle(host: host) { _ in .init(404, body: #"{"message":"Could not find page"}"#) }
        await #expect(throws: NotionClient.Failure.pageNotShared) {
            _ = try await client().createPage(parent: pageID, title: "T", children: [])
        }
        #expect(NotionClient.Failure.pageNotShared.errorDescription
            == "Halaman Notion tidak ditemukan. Pastikan halaman sudah dibagikan ke integrasi lewat Connections.")
    }

    @Test func createPageSendsParentTitleAndChildren() async throws {
        StubURLProtocol.handle(host: host) { _ in .init(200, body: #"{"id":"new-page"}"#) }
        let id = try await client().createPage(parent: pageID, title: "Rapat", children: blocks(2))
        #expect(id == "new-page")
        let body = try #require(StubURLProtocol.requests(host: host).first?.json)
        let parent = body["parent"] as? [String: String]
        #expect(parent == ["type": "page_id", "page_id": pageID])
        let title = (((body["properties"] as? [String: Any])?["title"]) as? [String: Any])?["title"] as? [Any]
        #expect(title?.count == 1)
        #expect((body["children"] as? [Any])?.count == 2)
    }

    @Test func moreThanHundredBlocksAreBatched() async throws {
        StubURLProtocol.handle(host: host) { _ in .init(200, body: #"{"id":"new-page"}"#) }
        _ = try await client().createPage(parent: pageID, title: "T", children: blocks(230))
        let requests = StubURLProtocol.requests(host: host)
        #expect(requests.map(\.method) == ["POST", "PATCH", "PATCH"])
        #expect(requests.map(\.path) == ["/v1/pages", "/v1/blocks/new-page/children", "/v1/blocks/new-page/children"])
        #expect(requests.map { ($0.json?["children"] as? [Any])?.count } == [100, 100, 30])
        let position = requests[1].json?["position"] as? [String: String]
        #expect(position == ["type": "end"])
    }

    @Test func retriesAfterTooManyRequestsThenGivesUp() async throws {
        let count = Counter()
        StubURLProtocol.handle(host: host) { _ in
            let n = count.next()
            return n <= 2 ? .init(429, headers: ["Retry-After": "2"]) : .init(200, body: #"{"id":"p"}"#)
        }
        _ = try await client().createPage(parent: pageID, title: "T", children: [])
        #expect(sleeps.values.withLock { $0 } == [2, 2])

        sleeps.values.withLock { $0 = [] }
        StubURLProtocol.handle(host: host) { _ in .init(429, body: #"{"message":"slow down"}"#) }
        await #expect(throws: NotionClient.Failure.http(429, "slow down")) {
            _ = try await client().createPage(parent: pageID, title: "T", children: [])
        }
        #expect(StubURLProtocol.requests(host: host).count == 4)
        #expect(sleeps.values.withLock { $0 } == [1, 1, 1])
    }

    @Test func otherErrorsCarryTheMessage() async {
        StubURLProtocol.handle(host: host) { _ in .init(401, body: #"{"message":"API token is invalid."}"#) }
        await #expect(throws: NotionClient.Failure.http(401, "API token is invalid.")) {
            _ = try await client().createPage(parent: pageID, title: "T", children: [])
        }
    }

    /// A page with 120 children listed over two pages.
    private func scriptReplace() {
        StubURLProtocol.handle(host: host) { request in
            if request.method == "GET" {
                if request.query.contains("start_cursor=c2") {
                    let rest = (100..<120).map { #"{"id":"b\#($0)"}"# }.joined(separator: ",")
                    return .init(200, body: #"{"results":[\#(rest)],"next_cursor":null,"has_more":false}"#)
                }
                let first = (0..<100).map { #"{"id":"b\#($0)"}"# }.joined(separator: ",")
                return .init(200, body: #"{"results":[\#(first)],"next_cursor":"c2","has_more":true}"#)
            }
            return .init(200, body: "{}")
        }
    }

    @Test func replaceContentRewritesThePage() async throws {
        scriptReplace()
        try await client().replaceContent(of: pageID, title: "Baru", with: blocks(130))
        let requests = StubURLProtocol.requests(host: host)
        #expect(requests[0].method == "PATCH")
        #expect(requests[0].path == "/v1/pages/\(pageID)")
        let property = (requests[0].json?["properties"] as? [String: Any])?["title"] as? [String: Any]
        let title = (property?["title"] as? [[String: Any]])?.first
        #expect(((title?["text"]) as? [String: Any])?["content"] as? String == "Baru")
        let gets = requests.filter { $0.method == "GET" }
        #expect(gets.count == 2)
        #expect(gets[0].path == "/v1/blocks/\(pageID)/children")
        #expect(gets[0].query.contains("page_size=100"))
        let deletes = requests.filter { $0.method == "DELETE" }
        #expect(deletes.count == 120)
        #expect(deletes.first?.path == "/v1/blocks/b0")
        #expect(deletes.last?.path == "/v1/blocks/b119")
        let appends = requests.filter { $0.method == "PATCH" && $0.path.hasSuffix("/children") }
        #expect(appends.map { ($0.json?["children"] as? [Any])?.count } == [100, 30])
        // Everything is deleted before anything is appended.
        let lastDelete = requests.lastIndex { $0.method == "DELETE" }!
        let firstAppend = requests.firstIndex { $0.method == "PATCH" && $0.path.hasSuffix("/children") }!
        #expect(lastDelete < firstAppend)
    }

    @Test func publishCreatesWithoutAStoredPageAndReplacesWithOne() async throws {
        StubURLProtocol.handle(host: host) { request in
            request.method == "POST" ? .init(200, body: #"{"id":"made"}"#)
                : .init(200, body: #"{"results":[],"next_cursor":null,"has_more":false}"#)
        }
        let created = try await client().publish(existing: nil, parent: pageID, title: "T", children: blocks(1))
        #expect(created == "made")
        #expect(StubURLProtocol.requests(host: host).map(\.method) == ["POST"])

        let again = try await client().publish(existing: "made", parent: pageID, title: "T", children: blocks(1))
        #expect(again == "made")
        #expect(!StubURLProtocol.requests(host: host).dropFirst().contains { $0.method == "POST" })
    }

    @Test func publishCreatesANewPageWhenTheStoredOneIsGone() async throws {
        StubURLProtocol.handle(host: host) { request in
            request.method == "POST" ? .init(200, body: #"{"id":"fresh"}"#) : .init(404, body: #"{"message":"gone"}"#)
        }
        let id = try await client().publish(existing: "old", parent: pageID, title: "T", children: blocks(1))
        #expect(id == "fresh")
        #expect(StubURLProtocol.requests(host: host).last?.method == "POST")
    }

    @Test func retryAfterIsCappedAndCursorsAreEncoded() async throws {
        let count = Counter()
        StubURLProtocol.handle(host: host) { request in
            if request.method == "GET" {
                return request.query.contains("start_cursor=")
                    ? .init(200, body: #"{"results":[],"has_more":false}"#)
                    : .init(200, body: #"{"results":[],"has_more":true,"next_cursor":"a b+c/="}"#)
            }
            return count.next() == 1 ? .init(429, headers: ["Retry-After": "3600"]) : .init(200, body: "{}")
        }
        try await client().replaceContent(of: pageID, title: "T", with: [])
        #expect(sleeps.values.withLock { $0 } == [60])
        let gets = StubURLProtocol.requests(host: host).filter { $0.method == "GET" }
        #expect(gets[1].url.absoluteString.hasSuffix("start_cursor=a%20b%2Bc%2F%3D"))
    }

    @Test func replaceKeepsSubPagesAndDatabases() async throws {
        StubURLProtocol.handle(host: host) { request in
            request.method == "GET"
                ? .init(200, body: #"{"results":[{"id":"p","type":"paragraph"},{"id":"sub","type":"child_page"},{"id":"db","type":"child_database"},{"id":"q","type":"to_do"}],"has_more":false}"#)
                : .init(200, body: "{}")
        }
        try await client().replaceContent(of: pageID, title: "T", with: [])
        let deleted = StubURLProtocol.requests(host: host).filter { $0.method == "DELETE" }.map(\.path)
        #expect(deleted == ["/v1/blocks/p", "/v1/blocks/q"])
    }

    @Test func createPageReportsItsIDBeforeAppending() async {
        StubURLProtocol.handle(host: host) { request in
            request.method == "POST" ? .init(200, body: #"{"id":"made"}"#) : .init(500, body: #"{"message":"boom"}"#)
        }
        let ids = Mutex<[String]>([])
        await #expect(throws: NotionClient.Failure.http(500, "boom")) {
            _ = try await client().createPage(parent: pageID, title: "T", children: blocks(230)) { id in
                ids.withLock { $0.append(id) }
            }
        }
        #expect(ids.withLock { $0 } == ["made"])
    }

    @MainActor
    @Test func partialSendKeepsThePageIDAndNextSendReplaces() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "NotulenTests-\(UUID().uuidString)")
        let store = AppStore(files: JSONFileStore(directory: directory), keychainPrefix: "test-\(UUID().uuidString)-")
        let saved = meeting()
        store.save(saved)
        let client = NotionClient(token: "t", session: StubURLProtocol.session) { _ in }
        let page = "1429989f-e8ac-4eff-bc8f-57f56486db54"

        // The second PATCH (blocks 201 on) fails.
        let patches = Counter()
        StubURLProtocol.handle(host: host) { request in
            if request.method == "POST" { return .init(200, body: #"{"id":"made"}"#) }
            if request.method == "PATCH", patches.next() == 2 { return .init(500, body: #"{"message":"boom"}"#) }
            return .init(200, body: #"{"results":[],"has_more":false}"#)
        }
        await #expect(throws: NotionClient.Failure.http(500, "boom")) {
            _ = try await store.publishToNotion(saved.id, using: client, parent: page, title: "T", children: blocks(230))
        }
        #expect(store.meeting(saved.id)?.notionPageID == "made")

        StubURLProtocol.handle(host: host) { _ in .init(200, body: #"{"results":[],"has_more":false}"#) }
        let again = try await store.publishToNotion(saved.id, using: client, parent: page, title: "T", children: blocks(230))
        #expect(again == "made")
        let requests = StubURLProtocol.requests(host: host)
        #expect(!requests.contains { $0.method == "POST" })
        #expect(requests.first?.path == "/v1/pages/made")
    }
}
