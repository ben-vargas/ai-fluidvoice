# Grok Speech (xAI) on upstream FluidVoice

This is a fresh build of Grok speech-to-text on upstream FluidVoice main (1.6.12 beta 1). It
replaces the old `feat/grok-streaming-stt` branch, which had drifted 300+ commits behind upstream.
The goal is to keep the old feature set while touching as little upstream code as possible, so
that future rebases stay cheap.

The branch has since been rebased onto upstream 1.6.13. That release added Fluid Parakeet Pro,
Qwen3 ASR 1.7B and a meeting overhaul; the hooks below carried over unchanged.

## How it fits

Grok is one more `SettingsStore.SpeechModel` case (`.grokSTT`). `GrokSTTProvider` is an ordinary
`TranscriptionProvider`, so the rest of the app treats it like any local engine. Grok text goes
through the same pipeline as other engines: filler removal, custom dictionary, spoken punctuation,
AI cleanup styles and prompts, history, and typing into the focused field.

| Path | What Grok does |
| --- | --- |
| Dictation preview | ASRService already polls `transcribeStreaming(fullBuffer)` on a timer. `GrokSTTDictationController` turns each poll into a push: it sends only the 100 ms frames the socket has not seen, then returns the socket's live transcript. |
| Dictation stop | `transcribeFinal` sends the remainder, sends `audio.done`, and waits for `transcript.done`. Interim text is never treated as final. If the socket times out, drops, or returns nothing before `transcript.done`, the whole recording is uploaded once over REST. |
| Dictation failure | `GrokSTTRetryCenter` keeps the audio in memory for 15 minutes and shows a Retry / Dismiss panel. A retry re-uploads over REST and applies local cleanup. If the failed recording was an ordinary dictation, the text then finishes through ContentView's `reprocessDictationText`, the same path as upstream's "reprocess last dictation": AI cleanup for the primary shortcut, history, and typing into the field that has focus when the retry succeeds. ContentView marks those recordings (`markPendingAsPlainDictation`). An Edit, Command, prompt-test, cancelled or onboarding capture is never marked, so its text is only shown with a Copy button. Dismissing, or starting a new recording, cancels a retry in flight. |
| Files | `prefersNativeFileTranscription` sends WAV, MP3, M4A, AAC, FLAC, OGG and Opus files to REST as-is. Other formats are decoded to 16 kHz mono and uploaded as WAV, in requests of up to 20 minutes. The local API uses the same paths. |
| Meetings | Upstream's default meeting backend always uses local Parakeet. While Grok is selected and the meeting's language is one Grok accepts, `MeetingProcessingPipeline` picks `GrokMeetingTranscriptionBackend` (`hosted-grok-stt-legacy-v1`). A meeting in any other language stays with upstream's local backend (`GrokMeetingTranscriptionBackend.handles`), so it is transcribed on the Mac and its audio is not uploaded; this covers new meetings, retries and Redo transcript alike. That backend runs the same in-pipeline workflow as the legacy backend, which transcribes with the selected engine, but it declares Grok's languages instead of English only. Meeting chunks are CAF, so they go through the decode-to-WAV path. `MeetingProviderLanguagePin` pins Grok to the meeting's language for the run. Speaker labels still come from the local diarizer. |
| Credentials | API key mode reuses the xAI key saved under AI Providers. Grok CLI session mode reads `~/.grok/auth.json` read-only and refreshes it by running `grok`. Until the user picks a mode, Grok uses the xAI key if one is saved, otherwise a Grok CLI session if one is on disk. `prepare` saves that choice, so adding a key later never moves a CLI user onto API billing. `prepare` only checks that the selected sign-in exists. Resolving and refreshing happen per request, so a failure keeps the recording for Retry. Errors never switch modes. The sign-in options open under the Grok row, and the list scrolls to them. |
| Dictionary training | Not supported. It throws a clear error that tells the user to pick a local engine. |

## Upstream files touched

Everything else lives in new files under `Sources/Fluid/Services/GrokSTT/`,
`Sources/Fluid/UI/GrokSTT/` and `Sources/Fluid/Persistence/SettingsStore+GrokSTT.swift`.

- `SettingsStore.swift`: adds the `.grokSTT` case and its switch arms, `Provider.xai`, and `isCloudEngine`.
- `ASRService.swift`: about 20 lines. It adds the provider cache and factory arms, and two calls into
  the generic `LiveSessionTranscriptionProvider` seam (`recordingSessionWillStart` in `start()`,
  `recordingSessionDidCancel` in `stopWithoutTranscription`).
- `SpeechModelInstallationSnapshot.swift`: Grok counts as built in.
- `ContentView.swift`: two lines. One installs `GrokSTTRetryCenter.deliverRecoveredDictation`, next to the other overlay callbacks; one marks a failed ordinary dictation in the empty-result branch.
- `BackupService.swift` and `SettingsStore.swift`: the optional `grokSTT` backup field, written in `makeBackupPayload` and read in `restore`. It holds the sign-in mode, the CLI path and the language, never a key or token.
- `Meeting/MeetingProcessingPipeline.swift`: asks `GrokMeetingTranscriptionBackend.handles(languageCode:)` whether Grok takes the meeting, and `MeetingProviderLanguagePin` gets a `.grok` case.
- `Meeting/Backend/MeetingTranscriptionBackendRegistry.swift`: registers the Grok backend (one line). `MeetingTranscriptionBackendTests` expects it in the default registry.
- `AISettingsView.swift`, `VoiceEngineSettingsViewModel.swift`, `AISettingsView+SpeechRecognition.swift`:
  the xAI filter chip, the credentials panel, the language menu, gating of the Activate button, and
  no Delete button for cloud engines.
- `Fluid.xcodeproj/project.pbxproj`: registers the test files. Sources use synchronized folders.

On a rebase conflict, re-apply these hooks by hand. They are small and mechanical.

`LiveSessionTranscriptionProvider` is engine-agnostic, so another cloud streaming engine could plug in
without touching ASRService again.

This work stays on Ben's fork. Upstream FluidVoice is local-models only and does not take cloud engines,
so none of it is proposed upstream. Never commit a personal `DEVELOPMENT_TEAM`: build signed with
`./build.sh` (or `FLUIDVOICE_DEVELOPMENT_TEAM=... ./build.sh`), which leaves the project file unchanged.

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

- Route a retried Edit or Command recording back into its own mode, and apply the secondary shortcut's prompt to a retried secondary dictation. Today those are copy-only and primary-prompt respectively.
- Move the Grok meeting backend to the canonical-evidence contract (word timings, receipts) once Grok returns word timestamps.
- Offer Grok-only languages (Japanese, Korean, Hindi and others) for meetings. Upstream's meeting
  language pickers list Parakeet's languages, so those can't be chosen yet.
- Add Grok to `VoiceEngineLanguageCatalog` and onboarding. Onboarding still never suggests a cloud
  engine, on purpose.
- Show a one-time notice before the first cloud upload of a meeting or file.
- Build keyterms off the main actor if the custom dictionary gets large.

## Tests

The test files live in `Tests/FluidDictationIntegrationTests/GrokSTT*Tests.swift`:

- Ported: audio converter, CLI auth store, credential resolver, keyterms, log redaction, REST client,
  transcript assembler, and WebSocket session.
- New: dictation controller (frame accounting, backpressure, handoff, REST fallback, generations,
  cancellation) and language/settings.

Upstream's tests run inside the FluidVoice Debug app and read its saved settings. Two
`MeetingTranscriptionBackendTests` cases expect the local meeting backend, so they fail while Grok is
the selected engine in FluidVoice Debug. Select a local engine there before running the suite.
