# Notulen (macOS, SwiftUI)

Native macOS app (Swift 6, SwiftUI) for the owner's own online meetings (Zoom,
Meet, Teams; 1–3 h, 7+ people). Captures meeting-app audio and the mic
separately, transcribes on device, shows live notes per topic during the
meeting, then separates the remote speakers on device and writes structured
minutes in Indonesian: summary, decisions, action items, open questions, topics.

Design (Indonesian): docs/superpowers/specs/2026-10-22-notulen-design.md. Read
it before changing behavior. UI mockups live in .superpowers/brainstorm/
(gitignored, local only).

## Layout
Update this section when it changes.
- Package.swift (SwiftPM). Builds with Command Line Tools only, no Xcode.
  `make build` bundles + ad-hoc signs .build/Notulen.app.
- App/Support: Info.plist (literal values, no $(VARS)), entitlements, icon
- App/Audio: AudioCapturing (protocol), ProcessTapCapture (Core Audio tap;
  re-attaches when the output device changes), MicCapture (AVAudioEngine;
  restarts on input device change; mic on/off), AudioConverter, AudioChunk,
  AudioLevel, AudioProcess, CoreAudioObject, OutputRoute + OutputRouteMonitor,
  MeetingAudioBuffer (meeting audio in RAM as 16 kHz mono Int16, for
  diarization only)
- App/Speech: SttProvider, SpeechAnalyzerProvider (SpeechTranscriber;
  DictationTranscriber for locales it lacks, e.g. id-ID; audioTimeRange per
  segment), custom vocabulary
- App/Diarization: SpeakerDiarizer (FluidAudio OfflineDiarizerManager over an
  in-memory AudioSampleSource; lines get the speaker with the most time
  overlap), DiarizationModels, SpeakerMatcher. Runs one at a time: concurrent
  FluidAudio runs hang Core ML.
- App/AI: LLMClient (purposes: liveNotes is fast; minutes and translation are
  smart), ClaudeClient, OpenAICompatibleClient, AIProvider, PromptTemplate,
  Schemas, JSONValue, TranscriptFormatter, LiveNotesUpdater, MinutesWriter,
  Translator
- App/Meeting: MeetingSession (capture → transcript → live notes),
  MeetingFinisher (diarize → minutes), TranscriptJournal (append + fsync per
  final line), PowerGuard + WakePolicy (no idle sleep while recording; wake
  rules), MeetingEndDetector, MicOffTracker, Speakers, MeetingTime,
  MeetingNotice, Transcript, TranscriptRows (lines plus gap and mic-off
  dividers, in time order). Crash recovery.
- App/Export: MinutesMarkdown, MinutesHTML + PDFExporter, NotionClient,
  NotionBlocks, NotionPageID, MinutesFormatting
- App/UI: sidebar, live view, processing, minutes, rename/merge speakers,
  settings (general, AI, Notion, About), TextScale
- App/Store: Codable models, JSONFileStore, Keychain, AppSettings, AppStore.
  JSON in ~/Library/Application Support/rakyat.notulen/meetings/<id>/
  (meeting.json + transcript.jsonl). No SwiftData: @Model's macro plugin needs
  Xcode.
- prompts/*.md: templates with {{variables}}, written in Indonesian. Don't
  rewrite unless asked.
- Code from ../interview-assistant is copied in and adapted, never linked.

## Commands
- `make build` (errors only) · `make run` · `make test` · `make install` ·
  `make uninstall` · `make icon` · `make models` (downloads the pinned
  diarization models into a gitignored folder; the bundle step copies them)
- Build after every change; fix errors before reporting done.
- No Xcode-only tools: no #Preview, no asset catalogs, no SwiftData macros, no
  @Entry. `@State` is a macro in the macOS 27 SDK: use `@ViewState` (same
  wrapper). SwiftPM runs with `--build-system native` (default backend needs Xcode).
- `make build` can stall while VS Code's SwiftPM helpers hold the .build lock.
  Don't kill other processes: wait, or close VS Code's Swift extension.
- If `swift build` hangs at "Downloading binary artifact", add `--disable-keychain`.

## Rules
- Exactly one AI provider is active. Anthropic is the default: claude-haiku-5-5
  for live notes; claude-sonnet-5-5 for minutes and translation. Other
  providers: the fast model for live notes, the smart model for the rest.
- AI replies are JSON (structured output); the app renders them. Minutes are
  always in Indonesian. Never invent owners, deadlines or decisions: null when
  nobody said them. AI text names speakers as tokens ([[s3]], [[me]]), rendered
  with the current names.
- Raw audio never touches disk. Meeting audio stays in RAM until diarization,
  then is zeroed. Never call FluidAudio's `process(url)` or
  `makeDiskBackedSource`: they write PCM to the temp dir. Don't store voice
  embeddings.
- FluidAudio is pinned `exact: "0.17.7"` with `traits: []`. Models are bundled
  and `ModelHub.offlineMode = true`. Keep the CC-BY-4.0 model attribution in
  About and README.
- API keys (AI provider, Notion) in Keychain only.
- Journal every final transcript line at once: a 3-hour transcript must survive
  crashes, sleep and device changes.
- UI: native macOS 26 SwiftUI components, one accent color (system blue), red
  only for recording. Text size via TextScale (⌘+ ⌘− ⌘0) for notes, transcript
  and minutes.
- Stay within the current task; don't refactor unrelated files.
