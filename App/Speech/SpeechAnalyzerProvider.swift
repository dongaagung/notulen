import AVFoundation
import CoreMedia
import Speech

/// On-device transcription with SpeechAnalyzer (macOS 26).
///
/// Two engines:
/// - SpeechTranscriber finalizes faster (0.8-1.8 s after speech ends) but
///   ignores contextual strings.
/// - DictationTranscriber uses the vocabulary but finalizes 0.5-1 s later. It
///   also covers more languages, Indonesian (id-ID) among them.
/// SpeechTranscriber is the default; DictationTranscriber is used when
/// SpeechTranscriber lacks the language.
/// Every result carries its audio range, so each update has a `span`.
struct SpeechAnalyzerProvider: SttProvider {
    enum Failure: LocalizedError {
        case unsupportedLocale(String)
        case noAudioFormat

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let id): "Pengenalan suara tidak mendukung \(id) di Mac ini."
            case .noAudioFormat: "Pengenalan suara tidak punya format audio yang bisa dipakai."
            }
        }
    }

    let locale: Locale
    /// Terms to expect, such as names and jargon of the meeting.
    /// Only DictationTranscriber uses them.
    var vocabulary: [String] = []

    /// Every language either engine supports, one entry per BCP 47 identifier.
    static func supportedLocales() async -> [Locale] {
        var byID: [String: Locale] = [:]
        for locale in await DictationTranscriber.supportedLocales + SpeechTranscriber.supportedLocales {
            byID[locale.identifier(.bcp47)] = locale
        }
        return byID.keys.sorted().compactMap { byID[$0] }
    }

    /// Downloads the on-device speech model for `locale` if it's missing,
    /// reporting the download's progress from 0 to 1.
    static func prepare(
        locale: Locale, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        _ = try await Engine.make(locale: locale, progress: progress)
    }

    func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncThrowingStream<TranscriptUpdate, any Error> {
        AsyncThrowingStream { output in
            let task = Task {
                do {
                    try await run(audio, output: output)
                    output.finish()
                } catch {
                    output.finish(throwing: error)
                }
            }
            output.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ audio: AsyncStream<AudioChunk>,
        output: AsyncThrowingStream<TranscriptUpdate, any Error>.Continuation
    ) async throws {
        let engine = try await Engine.make(locale: locale)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [engine.module]) else {
            throw Failure.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [engine.module])
        let (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        if case .dictation = engine, !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try await analyzer.start(inputSequence: inputs)

        let results = Task {
            try await engine.forEachResult { output.yield($0) }
        }

        // Runs until capture stops (the audio stream finishes) or we're cancelled.
        var converter = AudioConverter(target: analyzerFormat)
        for await chunk in audio {
            if let converted = try? converter.convert(chunk.buffer) {
                inputContinuation.yield(AnalyzerInput(buffer: converted))
            }
        }
        inputContinuation.finish()

        if Task.isCancelled {
            await analyzer.cancelAndFinishNow()
        } else {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        try await results.value
    }

    /// The speech module doing the recognition.
    private enum Engine: Sendable {
        case transcriber(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var module: any SpeechModule {
            switch self {
            case .transcriber(let module): module
            case .dictation(let module): module
            }
        }

        static func make(
            locale: Locale,
            progress: (@Sendable (Double) -> Void)? = nil
        ) async throws -> Engine {
            let transcriberLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            let dictationLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale)
            let engine: Engine
            if let dictationLocale, transcriberLocale == nil {
                engine = .dictation(DictationTranscriber(
                    locale: dictationLocale, contentHints: [], transcriptionOptions: [.punctuation],
                    reportingOptions: [.volatileResults, .frequentFinalization],
                    attributeOptions: [.audioTimeRange]))
            } else if let transcriberLocale {
                engine = .transcriber(SpeechTranscriber(
                    locale: transcriberLocale, transcriptionOptions: [],
                    reportingOptions: [.volatileResults, .fastResults],
                    attributeOptions: [.audioTimeRange]))
            } else {
                throw Failure.unsupportedLocale(locale.identifier(.bcp47))
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [engine.module]) {
                let reporter = Task {
                    while !Task.isCancelled {
                        progress?(request.progress.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                }
                defer { reporter.cancel() }
                try await request.downloadAndInstall()
            }
            return engine
        }

        func forEachResult(_ body: (TranscriptUpdate) -> Void) async throws {
            switch self {
            case .transcriber(let module):
                for try await result in module.results {
                    body(TranscriptUpdate(
                        text: String(result.text.characters), isFinal: result.isFinal, span: Self.span(result.range)))
                }
            case .dictation(let module):
                for try await result in module.results {
                    // Dictation sometimes doubles end punctuation ("Debezium??").
                    let text = String(result.text.characters).replacing(/([?.!])\1+/) { String($0.output.1) }
                    body(TranscriptUpdate(text: text, isFinal: result.isFinal, span: Self.span(result.range)))
                }
            }
        }

        /// Seconds from the stream's start; nil when CMTime is invalid or indefinite.
        private static func span(_ range: CMTimeRange) -> TimeSpan? {
            let start = range.start.seconds, end = range.end.seconds
            guard start.isFinite, end.isFinite else { return nil }
            return TimeSpan(start: start, end: end)
        }
    }
}
