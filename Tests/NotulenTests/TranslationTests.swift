import Foundation
import Testing
@testable import Notulen

private func source() throws -> Minutes {
    let url = try #require(Bundle.module.url(forResource: "minutes", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONReply.decode(Minutes.self, from: String(contentsOf: url, encoding: .utf8))
}

private func translator(_ client: FakeLLMClient) throws -> Translator {
    Translator(client: client, template: try PromptTemplate.load("translate"))
}

private func json(_ minutes: Minutes) throws -> String {
    String(decoding: try JSONEncoder().encode(minutes), as: UTF8.self)
}

/// Every text changed, the rest as it was.
private func translated(_ minutes: Minutes) -> Minutes {
    var result = minutes
    result.titleSuggestion = "Weekly Sync Product Team"
    result.summary = "EN " + minutes.summary
    result.decisions = minutes.decisions.map { var d = $0; d.text = "EN " + d.text; return d }
    result.actionItems = minutes.actionItems.map { var a = $0; a.task = "EN " + a.task; a.due = a.due.map { _ in "next Friday" }; return a }
    result.openQuestions = minutes.openQuestions.map { var q = $0; q.question = "EN " + q.question; return q }
    result.topics = minutes.topics.map { var t = $0; t.title = "EN " + t.title; t.points = t.points.map { "EN " + $0 }; return t }
    return result
}

struct TranslationTests {
    @Test func translationKeepsStructure() async throws {
        let original = try source()
        let changed = translated(original)
        let fake = FakeLLMClient(reply: try json(changed))
        let result = try await translator(fake).translate(original, to: "en")
        #expect(result == changed)
        #expect(result.hasSameStructure(as: original))
        #expect(result.actionItems.map(\.id) == original.actionItems.map(\.id))
        #expect(fake.requests.first?.purpose == .translation)
    }

    @Test func droppedItemIsRejected() async throws {
        let original = try source()
        var dropped = translated(original)
        dropped.actionItems.removeLast()
        let fake = FakeLLMClient(reply: try json(dropped))
        let translator = try translator(fake)
        await #expect(throws: Translator.Failure.structureChanged) {
            try await translator.translate(original, to: "en")
        }
        #expect(Translator.Failure.structureChanged.errorDescription == "Terjemahan tidak cocok dengan notulen aslinya. Coba lagi.")
    }

    @Test func tokensSurviveInTranslation() throws {
        var original = try source()
        original.summary = "[[s1]] membuka rapat. [[me]] menutup."
        original.decisions[0].text = "[[s2]] setuju."
        var good = translated(original)
        good.summary = "[[me]] closed what [[s1]] opened."
        good.decisions[0].text = "[[s2]] agreed."
        #expect(good.hasSameStructure(as: original))
    }

    @Test func changedTokenIsRejected() throws {
        var original = try source()
        original.summary = "[[s1]] membuka rapat. [[me]] menutup."
        var changed = original
        changed.summary = "Speaker 1 opened. [[me]] closed."
        #expect(!changed.hasSameStructure(as: original))
        var added = original
        added.summary = "[[s1]] opened. [[me]] closed. [[s2]] listened."
        #expect(!added.hasSameStructure(as: original))
        var reordered = original
        reordered.summary = "[[me]] closed after [[s1]] opened."
        #expect(reordered.hasSameStructure(as: original))
    }

    @Test func changedNumbersOrOwnersAreRejected() throws {
        let original = try source()
        var time = original
        time.decisions[0].at += 1
        #expect(!time.hasSameStructure(as: original))
        var owner = original
        owner.actionItems[0].owner?.speaker = .me
        #expect(!owner.hasSameStructure(as: original))
        var id = original
        id.openQuestions[0].id = "q9"
        #expect(!id.hasSameStructure(as: original))
        var topic = original
        topic.topics[0].end += 5
        #expect(!topic.hasSameStructure(as: original))
        var hint = original
        hint.speakerNameHints = []
        #expect(!hint.hasSameStructure(as: original))
        var points = original
        points.topics[0].points.removeLast()
        #expect(!points.hasSameStructure(as: original))
    }

    @Test func tokenMovedBetweenFieldsIsRejected() throws {
        var original = try source()
        original.topics[0].points = ["[[s1]] satu.", "dua."]
        original.actionItems[0].task = "[[s1]] kerjakan"
        original.actionItems[0].due = "kata"
        var points = original
        points.topics[0].points = ["satu.", "[[s1]] dua."]
        #expect(!points.hasSameStructure(as: original))
        var due = original
        due.actionItems[0].task = "kerjakan"
        due.actionItems[0].due = "[[s1]] kata"
        #expect(!due.hasSameStructure(as: original))
    }

    @Test func languageCodesAreNormalized() {
        #expect(Translator.normalized("EN") == "en")
        #expect(Translator.normalized(" zh-hans ") == "zh-Hans")
        #expect(Translator.normalized("pt-br") == "pt-BR")
    }

    @Test func requestNamesTargetLanguage() throws {
        let original = try source()
        let request = try translator(FakeLLMClient(reply: "{}")).request(original, to: "en")
        #expect(request.messages[0].content.contains("en"))
        #expect(request.messages[0].content.contains("Weekly Sync Tim Produk"))
        #expect(request.system.contains("en"))
        #expect(request.purpose == .translation)
        #expect(request.maxTokens == 64000)
    }

    @Test func languageCodeValidation() {
        for ok in ["en", "zh-Hans", "pt-BR", "fil", "es-419"] { #expect(Translator.isValidLanguageCode(ok), "\(ok)") }
        for bad in ["id", "ID", "id-ID", "id-Latn", "", " ", "e", "english", "en_US", "en-", "-en", "e1"] { #expect(!Translator.isValidLanguageCode(bad), "\(bad)") }
        #expect(Translator.languageName("en") == "Inggris")
        #expect(Translator.languageName("zh-Hans") != nil)
        #expect(Translator.languageName("xx") == nil)
    }
}

@MainActor
struct TranslationFinisherTests {
    private func setup(reply: String) throws -> (MeetingFinisher, AppStore, Meeting, Minutes) {
        let root = FileManager.default.temporaryDirectory.appending(path: "NotulenTests-\(UUID().uuidString)")
        let store = AppStore(files: JSONFileStore(directory: root), keychainPrefix: "test-\(UUID().uuidString)-")
        let minutes = try source()
        let meeting = Meeting(
            title: "T", startedAt: Date(timeIntervalSince1970: 1_800_000_000), status: .ready, language: "id-ID",
            audioSource: .systemWide, minutes: minutes)
        store.save(meeting)
        let translator = try translator(FakeLLMClient(reply: reply))
        let finisher = MeetingFinisher(store: store, diarizer: nil, writer: { nil }, translator: { translator })
        return (finisher, store, meeting, minutes)
    }

    @Test func storesTranslationByLanguage() async throws {
        let original = try source()
        let (finisher, store, meeting, _) = try setup(reply: try json(translated(original)))
        await finisher.translate(meeting.id, to: "en")
        #expect(store.meeting(meeting.id)?.translations["en"] == translated(original))
        #expect(finisher.translating.isEmpty)
        #expect(store.lastError == nil)
    }

    @Test func indonesianAndCaseVariantsAreHandled() async throws {
        let original = try source()
        let (finisher, store, meeting, _) = try setup(reply: try json(translated(original)))
        await finisher.translate(meeting.id, to: "id")
        await finisher.translate(meeting.id, to: "id-ID")
        #expect(store.meeting(meeting.id)?.translations.isEmpty == true)
        await finisher.translate(meeting.id, to: "EN")
        #expect(store.meeting(meeting.id)?.translations.keys.sorted() == ["en"])
    }

    @Test func rejectedTranslationIsNotStoredAndReportsError() async throws {
        var bad = translated(try source())
        bad.decisions.removeLast()
        let (finisher, store, meeting, _) = try setup(reply: try json(bad))
        await finisher.translate(meeting.id, to: "en")
        #expect(store.meeting(meeting.id)?.translations.isEmpty == true)
        #expect(store.lastError == "Terjemahan gagal: Terjemahan tidak cocok dengan notulen aslinya. Coba lagi.")
    }
}
