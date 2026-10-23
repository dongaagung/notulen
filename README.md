# Notulen

A native macOS app that records an online meeting from start to end,
transcribes it on your Mac, and writes the minutes: a summary of each topic
discussed, decisions, action items and open questions.

*Notulen* is Indonesian for meeting minutes. The minutes are written in
Indonesian.

Speech recognition and speaker separation run on your Mac. The AI parts (live
notes, minutes, translation) use one AI provider of your choice: Anthropic by
default, or any OpenAI-compatible one.

## Features

- **Live notes**: captures the meeting app's audio and your microphone
  separately, shows a live transcript and notes grouped by topic while the
  meeting runs.
- **Minutes**: when you stop, the app writes a summary per topic, decisions,
  action items (owner and deadline only if someone said them) and open
  questions.
- **Speaker separation**: after the meeting, the remote speakers are told apart
  on your Mac. You can rename and merge speakers afterwards.
- **Translation**: translate the minutes, for example to English.
- **Export**: Markdown, PDF, or send to a Notion page.
- **Resilience**: every final transcript line is saved at once, so a crash is
  recoverable. The Mac doesn't idle-sleep while recording, and the app copes
  with sleep, headphones being unplugged and output device changes.
- **Mic toggle**: turn your microphone off and on during a meeting (⇧⌘M),
  for example when you mute yourself in Zoom.
- **Text size**: ⌘+, ⌘− and ⌘0 scale notes, transcript and minutes.

## Requirements

- macOS 26 or later
- Command Line Tools with Swift 6.2 or later (`xcode-select --install`).
  Xcode is not needed.
- [xcbeautify](https://github.com/cpisciotta/xcbeautify), which the Makefile
  uses to shorten build output: `brew install xcbeautify`
- Internet once, so `make models` can download the speaker separation models.
  They are then bundled into the app, which never downloads at runtime.
- An API key for one AI provider, or a local [Ollama](https://ollama.com)

## Build and run

```sh
make run        # debug build, bundled and signed as .build/Notulen.app, then opened
make test       # run the tests (make test FILTER=SomeTests for a subset)
make models     # download the speaker separation models again
make install    # release build into /Applications/Notulen.app
make uninstall  # remove it from /Applications (your meetings stay)
make icon       # redraw App/Support/AppIcon.icns
```

`make build` builds without opening the app. The first build runs
`make models` by itself if the models are missing.

## First run

1. Open Settings (⌘,), choose an AI provider and paste its API key, which is
   saved in your Keychain. Ollama runs on your Mac and needs no API key.
2. Pick the default language for meetings.
3. Allow microphone, system audio recording and speech recognition when macOS
   asks.
4. Use headphones so the microphone doesn't pick up the other speakers.

Then start a new meeting (⌘N), choose the audio source and language, and press
Mulai.

## AI providers

Only one provider is active at a time.

| Provider | Live notes | Minutes and translation |
| --- | --- | --- |
| Anthropic (default) | `claude-haiku-5-5` | `claude-sonnet-5-5` |
| OpenAI, Google Gemini, DeepSeek, Groq, OpenRouter, Ollama, or another OpenAI-compatible server | your "fast" model | your "smart" model |

The prompts are tuned for Claude, so other models may answer differently.
They live in [prompts/](prompts/) as Markdown templates with `{{variables}}`.

## Notion

1. Create an internal integration at notion.so/profile/integrations and copy
   its token.
2. Share the parent page with the integration: page menu, Connections, add it.
3. In Settings, Notion tab, paste the token and the parent page's URL.

The first send creates a sub-page of that page; sending the same meeting
again updates that sub-page instead of making a new one.

## Privacy

- Audio never leaves your Mac and is never written to disk. Meeting audio is
  held in memory until speaker separation finishes, then wiped.
- Only text goes out: transcript and notes to the AI provider you chose, and
  the minutes to Notion if you send them.
- API keys (AI provider and Notion) are kept in the Keychain only.
- Meetings, transcripts and settings are saved as JSON in
  `~/Library/Application Support/rakyat.notulen`.

## Attribution

Speaker separation uses [FluidAudio](https://github.com/FluidInference/FluidAudio)
(Apache-2.0) and the pyannote community-1 models (CC-BY-4.0) from pyannote,
WeSpeaker, BUT Speech@FIT and Fluid Inference. The same note is in the app's
About tab.

## Project layout

```text
App/
  Audio/         meeting-app audio (Core Audio process tap), microphone, in-memory buffer
  Speech/        on-device speech recognition
  Diarization/   speaker separation (FluidAudio)
  AI/            provider clients (Anthropic, OpenAI-compatible), live notes, minutes, translation
  Meeting/       live session, transcript journal, sleep and wake rules, finishing a meeting
  Export/        Markdown, PDF, Notion
  UI/            SwiftUI views
  Store/         Codable models, JSON storage, Keychain, settings
  Support/       Info.plist, entitlements, app icon
Tests/           unit tests
prompts/         prompt templates
scripts/         model download, icon generator
Models/          downloaded diarization models (gitignored)
```

Notes for working on the code, including the no-Xcode constraints, are in
[CLAUDE.md](CLAUDE.md).
