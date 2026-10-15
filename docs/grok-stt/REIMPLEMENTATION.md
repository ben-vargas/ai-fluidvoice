# Grok Speech (xAI) on upstream FluidVoice

This is a fresh build of Grok speech-to-text on upstream FluidVoice main (1.6.12 beta 1). It
replaces the old `feat/grok-streaming-stt` branch, which had drifted 300+ commits behind upstream.
The goal is to keep the old feature set while touching as little upstream code as possible, so
that future rebases stay cheap.

## How it fits

Grok is one more `SettingsStore.SpeechModel` case (`.grokSTT`). `GrokSTTProvider` is an ordinary
`TranscriptionProvider`, so the rest of the app treats it like any local engine. Grok text goes
through the same pipeline as other engines: filler removal, custom dictionary, spoken punctuation,
AI cleanup styles and prompts, history, and typing into the focused field.

| Path | What Grok does |
| --- | --- |
| Dictation preview | ASRService already polls `transcribeStreaming(fullBuffer)` on a timer. `GrokSTTDictationController` turns each poll into a push: it sends only the 100 ms frames the socket has not seen, then returns the socket's live transcript. |
| Dictation stop | `transcribeFinal` sends the remainder, sends `audio.done`, and waits for `transcript.done`. If the socket produced nothing, it falls back to one REST upload of the whole recording. |
| Dictation failure | `GrokSTTRetryCenter` keeps the audio in memory for 15 minutes and shows a Retry / Dismiss panel. A retry re-uploads over REST, applies local cleanup, and shows the text with a Copy button. It never types on its own, because the failed recording may have been an Edit, Command or prompt-test capture that only ContentView knows how to route. Dismissing, or starting a new recording, cancels a retry in flight. |
| Files | `prefersNativeFileTranscription` sends WAV, MP3, M4A, AAC, FLAC, OGG and Opus files to REST as-is. Other formats are decoded to 16 kHz mono and uploaded as WAV, in requests of up to 20 minutes. The local API uses the same paths. |
| Meetings | Upstream's default meeting backend always uses local Parakeet. When a cloud engine is selected, `MeetingProcessingPipeline` picks the older `legacyCompatibility` backend instead, because that one transcribes with the selected engine. Meeting chunks are CAF, so they go through the decode-to-WAV path. `MeetingProviderLanguagePin` pins Grok to the meeting's language for the run. Speaker labels still come from the local diarizer. |
| Credentials | API key mode reuses the xAI key saved under AI Providers. Grok CLI session mode reads `~/.grok/auth.json` read-only and refreshes it by running `grok`. Errors never switch modes. |
| Dictionary training | Not supported. It throws a clear error that tells the user to pick a local engine. |

## Upstream files touched

Everything else lives in new files under `Sources/Fluid/Services/GrokSTT/`,
`Sources/Fluid/UI/GrokSTT/` and `Sources/Fluid/Persistence/SettingsStore+GrokSTT.swift`.

- `SettingsStore.swift`: adds the `.grokSTT` case and its switch arms, `Provider.xai`, and `isCloudEngine`.
- `ASRService.swift`: about 20 lines. It adds the provider cache and factory arms, and two calls into
  the generic `LiveSessionTranscriptionProvider` seam (`recordingSessionWillStart` in `start()`,
  `recordingSessionDidCancel` in `stopWithoutTranscription`).
- `SpeechModelInstallationSnapshot.swift`: Grok counts as built in.
- `Meeting/MeetingProcessingPipeline.swift`: cloud engines select the legacy backend, and `MeetingProviderLanguagePin` gets a `.grok` case.
- `AISettingsView.swift`, `VoiceEngineSettingsViewModel.swift`, `AISettingsView+SpeechRecognition.swift`:
  the xAI filter chip, the credentials panel, the language menu, gating of the Activate button, and
  no Delete button for cloud engines.
- `Fluid.xcodeproj/project.pbxproj`: registers the test files. Sources use synchronized folders.

On a rebase conflict, re-apply these hooks by hand. They are small and mechanical.

`LiveSessionTranscriptionProvider` is engine-agnostic. It is the seam to offer upstream later so that
any cloud streaming engine can plug in without touching ASRService again.

## Deferred work

### Meeting live captions (Ben asked for this to be tracked)

Meetings get the final Grok transcript today. Live captions still come from the local Parakeet EOU
engine, so they need a downloaded local model.

To add Grok captions:

1. Write `GrokMeetingLiveRecognizer: MeetingLiveRecognizer`
   (`Services/Meeting/LiveTranscription/MeetingLiveTrackEngine.swift`). Each call maps to the socket:
   - `prepareModels` resolves the credential.
   - `appendAudio` resamples to 16 kHz mono PCM16 and sends it with `GrokSTTWebSocketSession.append`.
   - `processBufferedAudio` is a no-op.
   - `reset` finishes the current socket and opens a new one.
   - Partial callbacks come from the session's `onPartial`.
   - EOU callbacks fire on `transcript.done`, or on a silence-endpoint segment boundary.
2. Inject it where `MeetingLiveTranscriptionCoordinator` builds `MeetingLiveTrackEngine(kind:)`, when
   `selectedSpeechModel == .grokSTT`. Microphone and application audio need one socket each.
3. Decide on reconnects for long meetings. xAI closes idle sockets, and there is a per-session duration
   cap. Rotate the socket on each EOU or every N minutes.
4. Label meeting captions as cloud processed in the meeting UI.

### Other follow-ups

- Send a retried dictation back through ContentView's normal completion (AI cleanup, history, Edit and Command routing). This needs a small upstream hook in ContentView. Until then, a retry only offers the text for copying.
- A dedicated hosted Grok meeting backend (`MeetingTranscriptionBackend`, `execution: .hosted`) to replace the legacy-path routing.
- Add Grok to `VoiceEngineLanguageCatalog` and onboarding. Onboarding still never suggests a cloud
  engine, on purpose.
- Add `grokSTTAuthMode`, `grokCLIBinaryPath` and `selectedGrokSTTLanguageCode` to settings backup.
- Show a one-time notice before the first cloud upload of a meeting or file.
- Build keyterms off the main actor if the custom dictionary gets large.

## Tests

The test files live in `Tests/FluidDictationIntegrationTests/GrokSTT*Tests.swift`:

- Ported: audio converter, CLI auth store, credential resolver, keyterms, log redaction, REST client,
  transcript assembler, and WebSocket session.
- New: dictation controller (frame accounting, backpressure, handoff, REST fallback, generations,
  cancellation) and language/settings.
