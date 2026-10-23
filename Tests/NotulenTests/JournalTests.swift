import Foundation
import Testing
@testable import Notulen

@MainActor
final class JournalTests {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "NotulenTests-\(UUID().uuidString)")
    var url: URL { root.appending(path: "meeting").appending(path: "transcript.jsonl") }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func line(_ text: String, start: TimeInterval) -> TranscriptLine {
        TranscriptLine(channel: .meeting, speaker: .remote(1), text: text, start: start, end: start + 2)
    }

    @Test func appendedLinesReadBack() throws {
        let journal = try TranscriptJournal(url: url)
        let a = line("Halo semuanya", start: 0)
        let b = line("Kita mulai rapat", start: 3)
        try journal.append(a)
        try journal.append(b)
        journal.close()
        #expect(try TranscriptJournal.read(url) == [a, b])
    }

    @Test func truncatedLastLineIsSkipped() throws {
        let journal = try TranscriptJournal(url: url)
        try journal.append(line("satu", start: 0))
        try journal.append(line("dua", start: 3))
        journal.close()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":""#.utf8))
        try handle.close()
        #expect(try TranscriptJournal.read(url).count == 2)
    }

    @Test func reopeningAppends() throws {
        let first = try TranscriptJournal(url: url)
        try first.append(line("satu", start: 0))
        first.close()
        let second = try TranscriptJournal(url: url)
        try second.append(line("dua", start: 3))
        second.close()
        #expect(try TranscriptJournal.read(url).count == 2)
    }

    @Test func resumeAfterTruncatedTailKeepsNewLine() throws {
        let journal = try TranscriptJournal(url: url)
        try journal.append(line("satu", start: 0))
        try journal.append(line("dua", start: 3))
        journal.close()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":""#.utf8))
        try handle.close()
        let resumed = try TranscriptJournal(url: url)
        try resumed.append(line("tiga", start: 6))
        resumed.close()
        #expect(try TranscriptJournal.read(url).map(\.text) == ["satu", "dua", "tiga"])
    }

    @Test func lastLineWithoutNewlineStillReads() throws {
        let journal = try TranscriptJournal(url: url)
        let a = line("satu", start: 0)
        try journal.append(a)
        journal.close()
        var data = try Data(contentsOf: url)
        data.removeLast()
        try data.write(to: url)
        #expect(try TranscriptJournal.read(url) == [a])
    }
}
