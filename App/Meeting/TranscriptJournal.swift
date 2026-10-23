import Foundation

/// Append-only JSONL journal: one final transcript line per row, synced to disk
/// at once so a long meeting survives a crash.
@MainActor
final class TranscriptJournal {
    private var handle: FileHandle?

    init(url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        let end = try handle.seekToEnd()
        if end > 0 {
            // A crash can leave a partial last row; keep it on its own line.
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            try reader.seek(toOffset: end - 1)
            if try reader.read(upToCount: 1) != Data([0x0A]) {
                try handle.write(contentsOf: Data([0x0A]))
            }
        }
        self.handle = handle
    }

    func append(_ line: TranscriptLine) throws {
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        var data = try JSONFileStore.lineEncoder.encode(line)
        data.append(0x0A)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    /// Skips rows that don't decode (a crash can cut the last one).
    nonisolated static func read(_ url: URL) throws -> [TranscriptLine] {
        let data = try Data(contentsOf: url)
        return data.split(separator: 0x0A).compactMap {
            try? JSONFileStore.decoder.decode(TranscriptLine.self, from: Data($0))
        }
    }
}
