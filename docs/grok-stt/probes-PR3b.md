# PR3b live probes — 2026-08-28

Authorized `wss://api.x.ai/v1/stt` probes recorded before wiring the production socket.
Fixture: `Tests/FluidDictationIntegrationTests/Resources/dictation_fixture.wav` (16 kHz mono PCM16 WAV, ~1.16 s). No personal speech.

Tokens are not recorded here. `refresh_token` was not decoded. `~/.grok/auth.json` was not written.

## Credentials

| Source | Present | Notes |
|---|---|---|
| xAI API key (`XAI_API_KEY` / `com.fluidvoice.stt-credentials`) | **No** | Not in process env, launchctl, or STT Keychain. LLM Keychain `com.fluidvoice.provider-api-keys` was not reused. |
| Grok CLI store (`~/.grok/auth.json` `key` field) | **Yes** | One unexpired entry (`expires_at` 2026-08-28T13:43:43Z at probe time 10:23Z). |

## Results

| ID | Case | Result | Evidence |
|---|---|---|---|
| **L2** | API-key WebSocket | **Skipped** | No API key available. Not faked. Same endpoint/protocol as L4. API-key socket still ships. |
| **L4** | CLI-token WebSocket | **Pass** | `transcript.created` (keys: `id`, `type`) then three `transcript.partial` (`is_final` false → true/`speech_final` false → true/`speech_final` true; textLen 19 each) then `transcript.done`. 200-class session, not 401. **CLI-socket enabled.** |
| **L5** | Wait-for-created | **Pass** | First server event was `transcript.created`. Client sent no audio before that event. |
| **L8** | Offline / unreachable | **Pass** | `wss://192.0.2.1/v1/stt` failed (`unreachable error`, ~3 s). Maps to `.offline` in `GrokSTTTransportErrorMapper`. |
| **L9** | Empty-socket REST retry | **Pass** | Socket closed after `transcript.created` before any audio/partials. REST `POST https://api.x.ai/v1/stt` with the same CLI Bearer returned **HTTP 200** with non-empty text (textLen 19). |
| **L10** | Non-empty socket + REST skipped | **Pass** | One CLI stream produced partials (textLen 19). Zero REST POSTs on that path. `transcript.done.text` was empty (textLen 0); assembler must keep partials (empty `replaceWithServerText` is a no-op). |

## Gate

L4 passed → **CLI-socket ships** (`SettingsStore.SpeechModel.grokSTTCLISocketEnabled = true`). API-key WebSocket ships either way. Dictation is the socket, not silent REST-on-stop.

## Protocol notes (from L4)

- Wait for `transcript.created` before binary PCM frames.
- `transcript.partial` carries `start`, `text`, `is_final`, `speech_final`, `duration`, `language`, `words`.
- Empty `transcript.done.text` must not wipe the assembler.
- `speech_final` is ignored for stop (hotkey `audio.done` only).
