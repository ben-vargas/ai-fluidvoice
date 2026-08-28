# Converged handoff spec — FluidVoice Grok streaming STT

**Date:** 2026-08-27  
**Status:** Ready for an implementing agent  
**How this was produced:** Three independent architectures (Grok design-skill writer+reviewer loop to 0 open issues; Claude Code opus-5 xhigh; Codex gpt-5.6-sol xhigh), then a convergence pass. Claude **SIGN-OFF**. Codex **SIGN-OFF** with merge conditions below.

## What to implement from

**Primary spec (implement this):** [`GROK-STT-DESIGN.md`](GROK-STT-DESIGN.md) (~1700 lines, PR1–PR5, types, ASRService start/stop/cancel, auth, tests).

**Independents (do not implement from these; they are the audit trail):**

- [`CLAUDE-ARCHITECTURE.md`](CLAUDE-ARCHITECTURE.md)
- [`CODEX-ARCHITECTURE.md`](CODEX-ARCHITECTURE.md)

## Locked product (do not re-open)

FluidVoice fork first · no Apple · WebSocket dictation · CLI `auth.json` + API-key fallback (device-flow later) · socket text is inserted · REST only if the socket produced **no usable transcript** · hotkey-only stop · visible Retry, no local fallback · meetings REST · STT keys ≠ LLM keys.

**Opt-in only.** Never default. Never selected by onboarding. Existing users keep their current engine. The user must pick **Grok Speech (xAI)** in Voice Engine settings and supply a credential.

**Rebase-friendly fork.** New code lives under `Sources/Fluid/Services/GrokSTT/` (plus a small session protocol file). Touch `ASRService` / `ContentView` / `SettingsStore` only at the documented branch points. No drive-by refactors of the local ASR path. Upstream process (issue vs discussion vs PR) is **out of scope** for this spec — decide after seeing how small the core-file diff actually is.

## Unanimous independently

- Parallel **session protocol** beside `TranscriptionProvider`; local engines keep the pull loop.
- `ASRService.start()` stays **non-blocking**; socket connect races capture.
- Auth is **bb**, not Quill: never write `auth.json`, never decode `refresh_token`, spawn `grok sessions list -n 1`, never kill, never bare `"grok"`.
- Pump PCM from `ThreadSafeAudioBuffer`, **not** a second realtime `pcmSink` on `AudioCapturePipeline` (Claude conceded this).
- Overlay must **not** hide before `stop()` on the default dictation path (`ContentView.swift:2108-2125`).
- Provider/session **off MainActor**; only partials hop to UI.

## Mandatory amendments to GROK-STT-DESIGN.md

An implementer must apply these even if a sentence in GROK-STT-DESIGN still says otherwise:

1. **Pre-`audio.done` drop (Codex + Claude):** if the socket dies **before** `audio.done`, **do not insert** even if the assembler has partial text. Treat as retryable (retain full `capturedPCM`). Insert-from-assembler is allowed only after a clean `audio.done` / `transcript.done` (or post-done transport error with non-empty text — Quill). This is the conservative reading of user decision 2C: “REST if the socket produced nothing” includes “produced only an incomplete mid-hold snapshot.”
2. **Auth UX (Codex):** two **explicit** STT modes in settings (Grok CLI session vs API key), not a silent precedence chain. Configured API key still wins when that mode is selected; an error must not switch billing modes.
3. **Catch-up (Grok rev 4):** one sender — the pump while `isRunning`. After `stop()` `getAll()`/`clear()`, `finish()` never reads `audioBuffer`; hand **entire** `capturedPCM` via `handoffUnsentPCM`.
4. **PR sequencing:** do **not** ship a user-visible REST-only dictation engine (Claude’s original PR3). Follow GROK-STT-DESIGN PR1 catalog (hidden, exhaustive arms) → PR2 auth **card visible, Activate off** → PR3a fake session tests → PR3b real WebSocket then Activate. Optional extra: Claude’s standalone PR to make `transcriptionProvider` exhaustive even without Grok.
5. **`modelsExistOnDisk() = false`**, `supportsStreaming = true`, plus an assertion `runStreamingLoop` never runs for this provider.
6. **Session testability (Codex):** inject a `WebSocketTransport`; prefer an actor-owned session so the pump does not inherit `@MainActor` from `ASRService` via unstructured `Task {}`.

## What not to take

- Claude’s `AudioCapturePipeline` pcmSink (extra copy on the realtime thread).
- Claude’s user-visible REST-only engine before WebSocket.
- Treating “2 s pre-ready ring exists today” as current FluidVoice behavior — it does not; GROK-STT-DESIGN specifies a **new** catch-up from sample 0, which is the right contract.

## Probe before PR3b

Authorized `wss://api.x.ai/v1/stt` with (1) API key and (2) CLI-store token. If (2) fails: ship API-key WebSocket; disable CLI-socket; do **not** silently REST-on-stop.
