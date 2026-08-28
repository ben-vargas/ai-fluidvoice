# Grok STT review notes

Minors from review rounds. Do not treat these as open PR work unless a later PR’s spec calls for them.

## PR1 review round 1

### Codex

- **Unsupported engines still advertise voice training** (`Sources/Fluid/Views/AutomaticDictionaryCorrectionOverlay.swift:649`). The Train by Voice action is hidden for cloud engines, but the preceding copy still says users can “teach FluidVoice other pronunciations.” Suggested: make that sentence conditional; for unsupported engines, describe saving the correction as a replacement only.

### Claude

- **Unreachable training-content branch leaves an empty padded panel** (`Sources/Fluid/Views/AutomaticDictionaryCorrectionOverlay.swift`). The “Voice training is unavailable…” explainer and the `if supportsPronunciationTraining` wrapper around the training panel body were dead code (`.training` is only reachable through the hidden button). Also filed as a major/overbuilt finding; the dead code was deleted in the round-1 fix. Recorded here because Claude also filed it as a minor.

- **README advertises an engine no user can select** (`README.md`). The Supported Models row for `Grok Speech (xAI)` includes “(hidden until credentials ship).” PR1 ships with `grokSTTCatalogVisible = false` and `grokSTTActivateEnabled = false`. GROK-STT-DESIGN asks PR1 for a models table row, so this is a judgement call rather than a spec miss. Suggested: move the row to PR3b, or reword the parenthetical to say the engine is not yet available in released builds.

## PR1 review round 2

### Codex

No items.

### Claude

- **U1 `modelsExistOnDisk` assertion was tautological** (`Tests/FluidDictationIntegrationTests/GrokSTTSpeechModelCatalogTests.swift`). Also filed as overbuilt/major; the private `modelsExistOnDiskEquivalent` extension was deleted in the round-2 fix and the test now asserts `GrokSTTCatalogStubProvider().modelsExistOnDisk()`. Suggested leftover polish: drop the `:34` conjunction (`usesAppleLogo && hasRemovableLocalArtifacts`); both operands are already asserted individually.

- **`showsVoiceEngineDownloadAction` was dead in production** (`Sources/Fluid/Persistence/SettingsStore.swift`). Also filed as overbuilt/major; the unused helper was deleted in the round-2 fix. U4 now asserts `model.isInstalled` (the view’s actual Download gate at `AISettingsView+SpeechRecognition.swift:449`) plus `showsVoiceEngineDeleteAction` (wired at `:467`).

- **Engine card omits the required API-key / CLI-session billing disclosure** (`Sources/Fluid/Persistence/SettingsStore.swift`). GROK-STT-DESIGN “Engine card copy (required)” specifies four paragraphs. PR1 ships paragraph 1 (`cardDescription`) and the proxy/client-key sentence (VoiceEngineSettingsViewModel advanced info only). Missing: API-key rate disclosure (~$0.20/hr streaming, ~$0.10/hr REST) and the Grok CLI session paragraph (experimental, undocumented, read-only `~/.grok/auth.json`, billing unknown, FluidVoice never writes that file). Assign those two paragraphs to **PR2**, which owns the auth card; do not assume PR1 already shipped them.

- **WelcomeView groups `.grokSTT` with `.automatic`/`.whisper`** (`WelcomeView.swift:2698`, `:2720`, `:2867`). Route-selection compares `onboardingSelectedLanguageID` and reports `languageChanged = false`, ignoring `selectedGrokSTTLanguageCode`. Unreachable today (`routeCandidates` never emits Grok; `testOnboardingRouteCandidatesDoNotIncludeGrok` locks that in); the arms exist to satisfy the exhaustive switch. Suggested: split `.grokSTT` into its own arm (`return false` / `languageChanged = false`) with a comment that Grok is intentionally excluded from onboarding.

- **Three Grok language helpers have no production caller in PR1** (`SettingsStore.grokSTTQueryLanguageParameter`, `VoiceEngineLanguageCatalog.grokSTTLanguages`, `grokSTTLanguageCode(for:)`). Leave them; they are consumed by PR3b/PR4 (the query param is the Auto-omits-`language` contract). If PR3b lands without using `grokSTTQueryLanguageParameter`, delete it then and fold U16’s Auto-omission assertion onto `grokSTTLanguageCode(fromStoredValue:)`.

## PR1 round 3

- **Cloud disclosure row hardcodes "xAI" behind a generic isCloudEngine gate** (`Sources/Fluid/UI/AISettingsView+SpeechRecognition.swift`). AISettingsView+SpeechRecognition.swift:228-236 renders the warning for any `model.isCloudEngine`, but the string is provider-specific ("Audio is sent to xAI."). Grok is the only cloud engine today so this is correct as shipped, but the gate and the copy are coupled to different things — a second cloud engine would silently claim its audio goes to xAI. `model.brandName` is already available on the card (used at :941/:962 for the badge). Suggested: Interpolate the provider: `Text("Audio is sent to \(model.brandName). This engine is opt-in and is not local-first.")`, or leave as-is and note the coupling for whichever PR adds a second cloud engine.

## PR2 review round 1

### Codex

No leftover minors. The GrokSTTError.server payload item was filed as blocking and fixed in this round (sanitize at `fromHTTPStatus`, redacted `description` / `debugDescription`, U19 covers describing and reflecting).

### Claude

- **GrokSTTError.server retains the unsanitized server message in its payload** (`Sources/Fluid/Services/GrokSTT/GrokSTTError.swift`). Filed as minor here and as blocking by Codex. Fixed in this round: server messages are sanitized before storage, and `String(describing:)` / `String(reflecting:)` no longer dump the raw associated value.

## PR2 review round 2

### Codex

No leftover minors. The three blocking/major items (unsanitized `.server` associated value, 401 recovery scoring expired entries, local-engine `selectedSpeechModel` credential I/O) were filed as blocking/major and fixed in this round.

### Claude

- **`isGrokSTTSelectable()` default arguments are still evaluated eagerly when the function is called** (`Sources/Fluid/Persistence/SettingsStore.swift`). Round-2 fixed `selectedSpeechModel` so local-engine reads never call this function (parse stored model first; `resolvedSpeechModel` takes `@autoclosure` and only invokes the gate for `.grokSTT`). Remaining: a direct `isGrokSTTSelectable()` call still evaluates `credentialSourceConfigured: Bool = grokSTTCredentialSourceConfigured` at the call site, including SwiftUI view-body sites (`AISettingsView+SpeechRecognition.swift` speechModelSubtitle / grokSTTActivateHint / grokCLISessionStatusText). Suggested: `@autoclosure () -> Bool` on that parameter, and cache the credential-source answer for view bodies.

- **`GrokCLIRefreshDelegate` never releases the retained child Process after it exits** (`Sources/Fluid/Services/GrokSTT/GrokCLIRefreshDelegate.swift`). `retainedProcess` is overwritten on the next refresh rather than cleared after `waitUntilExit()`, so this is a bounded one-object leak. Suggested: `self.lock.withLock { self.retainedProcess = nil }` after the wait returns.

## PR2 review round 3

### Codex

- **Nonisolated model helper calls MainActor state** (`Sources/Fluid/Persistence/SettingsStore.swift:4599`). The focused build warns at lines 4604 and 4607 because `resolvedSpeechModel` is `nonisolated` but reads MainActor-isolated `defaultModel`. This becomes an error in Swift 6 mode. Suggested: remove the unnecessary `nonisolated` annotation or make the safe dependency explicitly nonisolated.

- **Async refresh uses unavailable lock operations** (`Sources/Fluid/Services/GrokSTT/GrokCLIRefreshDelegate.swift:115`). The build warns that direct `NSLock.lock()` and `unlock()` calls are unavailable from asynchronous contexts and become errors in Swift 6 mode. Suggested: `lock.withLock { retainedProcess = process }`.

### Claude

- **Ordered-JSON key scanner doesn't unescape, so escaped scope keys silently drop entries** (`Sources/Fluid/Services/GrokSTT/GrokCLIAuthStore.swift`). `GrokCLIOrderedJSONKeys.keys(in:)` collects raw bytes between quotes without decoding JSON string escapes, while `JSONDecoder` produces unescaped dictionary keys. In `decodeEntries` any ordered key containing an escape sequence fails the `object[scopeKey]` lookup and is skipped. The `orderedKeys.isEmpty ? Array(object.keys) : orderedKeys` fallback only fires when the scanner returns nothing at all. Low probability in practice — Node/Bun/Go/Rust/Python serializers do not escape `/`, and issuer/client-id are ASCII. Suggested: after building `keys`, append any `object.keys` not present in the ordered list (or fall back to `Array(object.keys)` when the ordered list does not cover every decoded key).

- **U28's end-to-end assertion on the real selectedSpeechModel getter was deleted** (`Tests/FluidDictationIntegrationTests/GrokSTTBackupRestoreTests.swift`). Commit 843e109 removed `testRestoringGrokSTTWhileCatalogHiddenFallsBackToDefaultModel`, which was the only test that set `SelectedSpeechModel = "grok-stt"` in UserDefaults and asserted `SettingsStore.shared.selectedSpeechModel == defaultModel`. The replacement (`testRestoringGrokSTTWithoutCredentialSourceFallsBackToDefaultModel`) only exercises the pure `SpeechModel.resolvedSpeechModel` helper, so the getter wiring at SettingsStore.swift:5855-5862 — `stored == .grokSTT && SpeechModel.isGrokSTTSelectable()` — is now uncovered. Suggested: restore the defaults-backed test (set/restore `SelectedSpeechModel` around the assertion) alongside the new helper-level test, asserting `SettingsStore.shared.selectedSpeechModel == SettingsStore.SpeechModel.defaultModel` for a stored `grok-stt` raw value.

## PR2 review round 4

### Codex

- **Async refresh uses Swift-6-incompatible lock calls** (`Sources/Fluid/Services/GrokSTT/GrokCLIRefreshDelegate.swift:115`). Direct `NSLock.lock()` / `unlock()` around `retainedProcess` is unavailable from async contexts and becomes an error under Swift 6. Safe under the current effective Swift 5 mode. Suggested: `lock.withLock { retainedProcess = process }`, and clear the retained process after `waitUntilExit()`.

- **Nonisolated restore helper references MainActor state** (`Sources/Fluid/Persistence/SettingsStore.swift:4599`). `resolvedSpeechModel` is `nonisolated` but returns MainActor-isolated `defaultModel`; the Fluid scheme warns at both defaultModel returns. No off-main caller today. Raised in round 3 and still present. Suggested: drop `nonisolated` or make `defaultModel` explicitly `nonisolated`.

- **Ordered-key scanner drops valid escaped JSON keys** (`Sources/Fluid/Services/GrokSTT/GrokCLIAuthStore.swift:294`). The scanner preserves raw escape sequences while `JSONDecoder` unescapes dictionary keys, so a valid auth store with an escaped scope key can silently omit that entry. Actual Grok serializers are unlikely to emit such keys. Suggested: decode collected key strings or append decoded object keys not covered by the ordered scan.

### Claude

- **`resolvedSpeechModel` is nonisolated but reads MainActor-isolated `defaultModel`** (`Sources/Fluid/Persistence/SettingsStore.swift`). Same two Fluid-scheme warnings as Codex (`:4604` and `:4607`). The helper has no off-main caller (both call sites are MainActor). Recorded in round 3 rather than fixed; warnings remain. Suggested: drop `nonisolated` on `resolvedSpeechModel`, or make `defaultModel` explicitly `nonisolated`.

- **Credential-source I/O runs inside SwiftUI view bodies** (`Sources/Fluid/UI/AISettingsView+SpeechRecognition.swift`). Rendering the Grok row performs synchronous Keychain and filesystem reads on the main thread on every body evaluation: `voiceEngineDisplayName` (:775) and `grokSTTActivateHint` (:785) both read `grokSTTCredentialSourceConfigured` → `SecItemCopyMatching` or a full read+JSON-decode of `~/.grok/auth.json`; `hasSavedGrokSTTAPIKey()` (:823) issues another Keychain query; `grokCLISessionStatusText` (:878) constructs a fresh `GrokCLIAuthStore()` and re-reads and re-parses the file. Up to four blocking I/O operations per render of the Voice Engine settings card. Recorded as a round-2 minor and still unaddressed. Suggested: resolve the credential-source answer and CLI session status once into `@State` (refreshed on appear and after Save/Delete/mode change).

- **SecureField is pre-filled with the real stored API key** (`Sources/Fluid/UI/AISettingsView+SpeechRecognition.swift`). `reloadGrokSTTCredentialDrafts()` copies the plaintext key out of the Keychain into `@State var grokSTTAPIKeyDraft` on every `onAppear` and whenever the preview model becomes `.grokSTT`. GROK-STT-DESIGN specifies only “SecureField + Save / Delete” — it does not ask for the stored key to be read back into the UI. Suggested: leave the draft empty and render a “Key saved” indicator (from `hasSavedGrokSTTAPIKey()`); only populate the field when the user is entering a new key.

- **U28's end-to-end selectedSpeechModel fallback assertion was deleted and not restored** (`Tests/FluidDictationIntegrationTests/GrokSTTBackupRestoreTests.swift`). Same leftover as round 3: the replacement only exercises the pure `resolvedSpeechModel` helper and `isGrokSTTSelectable`, so the production getter composition (`SettingsStore.swift:5859-5862`) is uncovered. Risk is bounded because `canActivateVoiceEngine == false` and `isGrokSTTSelectable` both independently block selection. Suggested: re-add the defaults-backed test alongside the helper-level one, saving and restoring the `SelectedSpeechModel` key around the assertion.

- **CLI-path Save with an empty draft reports “Saved” while actually clearing the setting** (`Sources/Fluid/UI/AISettingsView+SpeechRecognition.swift`). The Save button assigns `settings.grokCLIBinaryPath = self.grokCLIBinaryPathDraft` unconditionally. The setter trims and removes the defaults key for an empty/whitespace value, so pressing Save on an empty field clears the override but the status line reads “Saved grok CLI path.” The same button also accepts a non-existent or non-executable path with a success message; `GrokCLIBinaryLocator` then silently ignores it and falls through to the default search paths. Suggested: disable Save when the trimmed draft is empty, and validate with `FileManager.isExecutableFile` before saving.

- **`GrokCLIRefreshDelegate` never releases the child Process after it exits** (`Sources/Fluid/Services/GrokSTT/GrokCLIRefreshDelegate.swift`). `retainedProcess` is set and only overwritten by the next refresh; it is not cleared after `await process.waitUntilExit()`. Bounded one-object retention, not a growing leak. Recorded as a round-2 minor and still unaddressed. Suggested: `self.lock.withLock { self.retainedProcess = nil }` after `waitUntilExit()` returns.

- **bb scoring can prefer an expired entry over a live one, forcing an unnecessary refresh** (`Sources/Fluid/Services/GrokSTT/GrokCLIAuthStore.swift`). `pick` applies the literal bb formula `(rotated ? 4 : 0) + (selfConsistent ? 2 : 0) + (expired ? 0 : 1)`, so an expired self-consistent entry (2) outranks an unexpired scope-mismatched entry (1); `testExpiredSelfConsistentBeatsUnexpiredMismatched` locks this in. In `resolveCredential` that pick triggers a delegated refresh, and if the grok binary cannot be located the call throws `.grokCLINotFound` even though a usable unexpired token was sitting in the store. The 401-recovery path pre-filters to unexpired entries, and no expired credential is ever returned. U6’s “expired never preferred over unexpired” wording conflicts with the Scoring block; CONVERGED-ARCHITECTURE locks “auth is bb, not Quill,” so the formula is the contract. Suggested leftover: if refresh fails, fall back to the best unexpired candidate before throwing — or leave as recorded.

- **Ordered-JSON key scanner does not unescape scope keys** (`Sources/Fluid/Services/GrokSTT/GrokCLIAuthStore.swift`). Same leftover as Codex / round 3: an ordered key containing an escape sequence fails the `object[scopeKey]` lookup and that entry is silently skipped. Low probability in practice. Suggested: after building `keys`, append any `object.keys` not covered by the ordered list.

## PR2 round 5

- **No test locks the GrokSTTCredential reflection redaction** (`Sources/Fluid/Services/GrokSTT/GrokSTTCredential.swift`). GrokSTTCredential stores the raw bearer. Its CustomDebugStringConvertible conformance (Sources/Fluid/Services/GrokSTT/GrokSTTCredential.swift:48-52) is the only thing preventing String(reflecting:)/dump() from printing that bearer, and it has no test. U19's redaction assertions (GrokSTTCredentialResolverTests.swift:246-330) exercise GrokSTTError and GrokSTTSanitizedMessage only. If someone later removes the conformance — as happened to the enum conformances in round 4 — the default reflection dump would print the bearer and every test would still pass. Suggested: Add one assertion alongside the existing U19 cases: build a GrokSTTCredential(bearer: "xai-secret-...", source: .grokCLISession, ...) and assert that String(describing:), String(reflecting:) and debugDescription contain neither the bearer nor its fingerprint.

## PR3a review round 1

### Codex

No leftover minors. Blocking/major items (pre-`audio.done` assembler insert, REST/Retry provider pinning, retry-store leak into local recordings, Retry routing, session generation isolation, stop-time PCM framing, test-only fake session) were filed as blocking/major and fixed in this round.

### Claude

- **created/handoff race can silently drop the whole utterance in PR3b** (`Sources/Fluid/Services/ASRService.swift`). `finishSessionTranscriptionBody` snapshots `createdReceived` before `finish()`, but the sibling start task used to set the session to `streaming` inside `session.start()` before `gate.markCreated()`. If `start()` lands in that window, stop takes the `!created` branch and calls `handoffUnsentPCM` on a session already in `streaming`, where the protocol declares handoff illegal. Round-1 now marks created only after the generation/session identity check, which narrows the window; a real WebSocket session that rejects handoff in `streaming` could still send `audio.done` with zero audio if created flips between the snapshot and the handoff. Suggested leftover: mark created before the session leaves `waitCreated`, or accept `handoffUnsentPCM` in `streaming` when nothing has been appended yet, and add a test that flips created between the snapshot read and the handoff.

- **U23/U29/U30 still exercise `startBypassingHardwareCapture`, not a live mic start** (`Sources/Fluid/Services/ASRService.swift`). Round-1 shrunk the bypass so it calls the same `startTranscriptionAfterCaptureBegan` helper as production `start()`, but the hardware-capture prologue remains a DEBUG replica. A regression in the real `start()` mic/permission/`isRunning` path before that helper would not fail these tests. Suggested: seam the audio-capture dependency instead of a second start method.

## PR3a review round 2

### Codex

Blocking/major items (engine reset cloud-to-local fallback, created-versus-handoff race, cancel waiting for `session.start()` before closing the socket, Retry dropping language and audio-history, unused `neverCreated` / dispatcher-only-enum coverage) were filed as blocking/major and fixed in this round.

### Claude

- **`cancelStreamingSession()` is not generation-scoped, so a slow stop can tear down the next recording's session** (`Sources/Fluid/Services/ASRService.swift`). `finishSessionTranscriptionBody` and `completeSessionWithRESTOrRetry` both call `cancelStreamingSession` after an unbounded await (`finish()` up to 3 s, then REST up to 60 s) without comparing `sessionGeneration`. The hotkey path is protected by `GlobalHotkeyManager.canTriggerRecordingAction` while `isProcessingStop` is true, but `ContentView.startRecording()` only guards `!asr.isRunningOrStarting`, both of which are false during `finish()`/REST, so the in-app record button and onboarding playground can start recording B mid-teardown. Consequence is graceful degradation to REST-at-stop for B, not data loss. Suggested: capture `sessionGeneration` at the top of `finishSessionTranscriptionBody` and no-op teardown when the generation has moved on; add a test that starts recording B while A's `finish()` is parked.

- **Keyterm build does synchronous vocabulary file I/O on MainActor while the user is already speaking** (`Sources/Fluid/Services/GrokSTT/GrokSTTKeytermBuilder.swift`). `startSessionTranscription` calls `GrokSTTKeytermBuilder.terms()`, which is `@MainActor` and performs `try? ParakeetVocabularyStore.shared.loadUserBoostTerms()` — a synchronous disk read plus decode after the start cue. Matches the spec text, so this is a latency nit. Suggested: cache the keyterm list (refresh on dictionary/vocabulary mutation and on `ensureAsrReady`) or build the configuration off MainActor.

- **Unreachable provider guard in `startSessionTranscription`** (`Sources/Fluid/Services/ASRService.swift`). The `guard let sessionProvider = self.transcriptionProvider as? StreamingTranscriptionProviding` can never fail: the only caller already selected this branch on exactly that cast, and nothing suspends between the two. The `.noCredentialConfigured` assignment is therefore dead. Suggested: pass the already-cast provider in as a parameter and drop the re-cast.

## PR3a review round 3

### Codex

Blocking/major items (Retry hidden after in-flight engine reset; unscoped stop teardown cancelling a newer session) were filed as blocking/major and fixed in this round.

### Claude

- **U15's entity→string mapping is untested** (`Tests/FluidDictationIntegrationTests/GrokSTTKeytermBuilderTests.swift`). `GrokSTTKeytermBuilderTests` only exercises the pure `terms(replacementTexts:vocabularyTexts:)` overload with already-mapped strings. The `@MainActor` overload that actually does `replacements.map(\.replacement)` and `vocabulary.map(\.text)` (`GrokSTTKeytermBuilder.swift:17-27`) — the exact thing U15's "replacements not triggers; Term.text not aliases" clause is guarding — has no coverage. A regression to `\\.trigger` or an alias field would keep every assertion green. `testReplacementsNotTriggersAndVocabularyTextNotAliases` even names the variable `fromEntries` but still passes raw strings. Suggested: add one case that builds real `SettingsStore.CustomDictionaryEntry` values (trigger != replacement) and `ParakeetVocabularyStore.VocabularyConfig.Term` values (text != aliases) and asserts the result contains the replacement/text and not the trigger/aliases.

- **Dictionary-training guard sits behind the empty-tap early return** (`Sources/Fluid/Services/ASRService.swift`). In `finishSessionTranscriptionBody` the `capturedPCM.isEmpty && transcript.isEmpty && sticky == nil` early return precedes the `useDictionaryTrainingPath` branch, so a zero-audio training capture on a session engine reports `lastStopOutcome = .empty` instead of surfacing `.dictionaryTrainingUnsupported`. Unreachable today (Train composer is gated on `!isCloudEngine` in CustomDictionaryView.swift:506 and Activate is off), but the two guards read as if training wins. Suggested: move the `useDictionaryTrainingPath` branch above the empty-tap early return.

- **REST-empty and REST-throw paths emit no stop_end benchmark line** (`Sources/Fluid/Services/ASRService.swift`). `completeSessionWithRESTOrRetry` logs `stop_end result=error` only on the no-provider guard. The two REST outcomes that also end the recording — empty result and thrown error — set `lastStopOutcome = .failed` and return `""` without a `benchmarkLog`, so those stops are invisible in the benchmark stream while every other stop path (success, empty tap, no-provider) is instrumented. Suggested: emit `benchmarkLog("stop_end result=error totalMs=... error=...")` in both the empty-REST and catch branches.

- **Fake session resumes continuations while holding its NSLock** (`Tests/FluidDictationIntegrationTests/GrokSTTFakeSession.swift`). `GrokSTTFakeSession.start()`, `cancel()` and `fail()` call `continuation?.resume(...)` from inside `lock.withLock { }`. If a resumed task synchronously re-enters any locked accessor (e.g. `transcript`, `currentState`) on the same thread, NSLock is not recursive and it deadlocks. It happens not to bite with the current tests, but the fake is carried into PR3b where more sessions will exercise it. Suggested: extract the continuation inside the lock, resume it after the lock is released (the pattern `TestLatch.resume()` in GrokSTTSessionHelpers.swift already uses).

## PR3a review round 4

### Codex

No leftover minors. Blocking/major items (stale stop-time sentCursor, start during undrained PCM, provider reset clearing Retry, U15 entity-field mapping) were filed as blocking/major and fixed in this round.

### Claude

- **shouldUseAI silently drops the getCurrentAppInfo() fallback for the AI-enhancement gate** (`Sources/Fluid/ContentView.swift`). Before this PR, `shouldUseAI` was recomputed inside the dictation path from `appInfo.bundleId`, where `appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()` (`ContentView.swift:2313`). It now reuses `context.shouldUseAIOnStop` (`:2330`), which was computed at `:2107-2108` from `self.recordingAppInfo?.bundleId` with no fallback. When `recordingAppInfo` is nil the per-app AI override of the frontmost app is no longer consulted. This actually makes the overlay-hide decision and the AI decision consistent (they previously could disagree), and `recordingAppInfo` is set by `captureRecordingTargetContext()` at every recording start, so the nil case is practically unreachable — worth a comment rather than a code change. Suggested: either note in `DictationStopRoutingContext` that `shouldUseAIOnStop` is intentionally bound to the captured recording app (not the current frontmost app), or pass the resolved `appInfo.bundleId` into the context when `recordingAppInfo` is nil.

- **Switching engines while the Retry banner is up makes Retry a silent no-op** (`Sources/Fluid/Services/ASRService.swift`). After a failed Grok stop the overlay shows the STT failure banner (`NotchContentState.isSTTFailureVisible`). If the user then switches voice engines, `resetTranscriptionProvider()` takes the non-deferred branch (`sessionOwnerLive` is already false). If a later change discards Retry without clearing `isSTTFailureVisible`, the Retry button stays on screen; pressing it calls `retryPendingGrokTranscription()`, `consume()` returns nil, and the same error banner is re-shown with no explanation. Suggested: when a path clears the retry store, also clear the overlay failure state (e.g. an ASRService-published signal ContentView observes, or have ContentView call `NotchContentState.shared.clearSTTFailure()` on speech-model change).

- **Redundant !context.isNormalRoute conjunct in the onboarding-tryout branch** (`Sources/Fluid/ContentView.swift`). `isOnboardingTryout` is built as `route == .onboardingSandbox && self.isOnboardingVoicePlaygroundStepActive` (`ContentView.swift:2097`), so it already implies `!isNormalRoute`. The extra conjunct at `:2434` never changes the outcome and reads as if two independent conditions matter. Suggested: drop `!context.isNormalRoute,` and keep `context.isOnboardingTryout`.

## PR3a review round 5

### Codex

No leftover minors. Blocking/major items (cancel teardown clearing a replacement local buffer, engine-switch overlay hide-before-stop, overlapping stop/start routing) were filed as blocking/major and fixed in this round.

### Claude

- **Stale STT failure banner survives into a command or rewrite recording** (`Sources/Fluid/ContentView.swift`). `NotchContentState.clearSTTFailure()` is called on the two dictation start paths (`ContentView.swift:3328` and `:4016`) but not on command (`:3616`) or rewrite (`:3636+`), which only call `advanceOverlayLifecycle()`. That helper clears `isAIProcessingFailureVisible` but not `isSTTFailureVisible`. After a failed Grok stop, command/rewrite leave the STT Retry banner on the overlay; pressing Retry is a no-op because `startTranscriptionAfterCaptureBegan` already cleared the retry store. Suggested: move `clearSTTFailure()` into `advanceOverlayLifecycle()` and drop the now-redundant dictation-start call sites.

- **Retry store holds up to ~38 MB of PCM past its TTL** (`Sources/Fluid/Services/GrokSTT/GrokSTTRetryStore.swift`). `hasPending` returns false after 15 minutes, but `pending` itself is never released until `clear()`/`consume()`. The next recording clears it in practice; an idle app after a failed Grok stop retains the buffer indefinitely rather than at the contracted 15-minute boundary. Suggested: have `hasPending` (or a small sweep) null out `pending` when the TTL elapses.

## PR3a review round 6

Blocking/major/overbuilt items applied in this round:

- **Credential preparation hopped off MainActor** (`GrokSTTProvider.prepare`). `ensureAsrReady` creates its readiness task on MainActor; the provider now runs `resolveCredential()` inside `Task.detached`, and `testEnsureAsrReadyResolvesCredentialOffMain` asserts the resolver executes off-main from the production readiness path.
- **STT Retry is serialized, start-gated, and holds routing ownership through dispatch** (`ASRService`, `ContentView.retryLastGrokSTT`). `isSTTRetryInFlight` joins `isRecordingStartBlocked`; `beginSTTRetryDispatch()`/`endSTTRetryDispatch()` claim Retry before the overlay is touched, duplicates are rejected without clobbering the in-flight retry, and ContentView releases the claim only after `dispatchSuccessfulTranscription` returns. Covered by `testStartDuringParkedRetryReturnsAlreadyActiveAndDuplicateRetryIsRejected`.
- **onPartial retain cycle broken** (`ASRService.startSessionTranscription`). The closure now weak-captures the session, and every teardown path (`cancelStreamingSession` owner + stale-generation, `resetTranscriptionProvider`) clears `onPartial`. Covered by `testSessionTeardownReleasesSession`.
- **Overbuilt removals**: `GrokSTTAudioConverter.wav()` (+ `testWAVHeaderPlusPCM`) deleted until a REST caller exists (PR3b/PR4); `ASRService.testStreamingSessionFactory` deleted — tests now inject sessions only through `GrokSTTProvider.setSessionFactory`, exercising the production factory path.
- **Retry vs provider-reset executor drain** (found while re-running the suite): `resetTranscriptionProvider()` drains the transcription executor asynchronously; a Retry that enqueued its REST call first could be cancelled and re-parked. `retryPendingGrokTranscription` now awaits the pending drain (same pattern as `ensureAsrReady`).

## PR3a round 1

```json
[
  {
    "severity": "minor",
    "title": "Trailing blank line fails diff check",
    "detail": "`git diff --check 808fd86..HEAD` reports a new blank line at EOF. This is non-functional polish and does not block approval.",
    "file": "Sources/Fluid/ContentView.swift",
    "suggestedFix": "Remove the extra blank line at the end of the file."
  }
]

## PR3b review round 1

### Codex

Blocking/major items (pre-`audio.done` send-state, concurrent drainers, done-timeout hang/leak, REST keyterms) were filed as blocking/major and fixed in this round.

### Claude

- **Reconnect-once on a post-upgrade 401 is inert** (`Sources/Fluid/Services/GrokSTT/GrokSTTWebSocketSession.swift`). `connectAndWaitCreated()` retries on 401 from `transport.connect` (covered by `testCLIUnauthorizedReconnectsOnce`). A 401 after a successful upgrade flows through the receive loop → `handleTransportFailure` → `fail()`, which sets `stickyError` and `state = .failed`. The retry reconnects but only promotes `.connecting → .waitCreated`, so the second `waitUntilCreated()` rethrows the stale 401. Latent today (xAI returns 401 at upgrade). Suggested: reset sticky error and state to `.connecting` before `continue`, or restrict the retry `catch` to connect-time errors and document post-upgrade 401s as terminal.

- **`append(pcm16:)` after finish/cancel no-ops without the specified debug assert** (`Sources/Fluid/Services/GrokSTT/GrokSTTWebSocketSession.swift`). GROK-STT-DESIGN says append after finish/cancel is illegal (no-op + assert in debug). The implementation still silently returns when `state != .streaming`, including the legitimate pre-`created` no-op. Suggested: debug-only assert for `.finishing` / `.cancelled` / `.complete` while keeping `.waitCreated` quiet.

- **Stale "Not activatable yet" hint copy is now unreachable and would be wrong if shown** (`Sources/Fluid/UI/AISettingsView+SpeechRecognition.swift`). `grokSTTActivateHint` still returns "Not activatable yet" when a credential source is configured. With Activate and CLI-socket enabled, `canActivateVoiceEngine` is false only when no credential source exists, so that string is only reachable via a "Needs credentials" path that already has its own copy. Suggested: delete the stale branch or replace it with Activate-available copy.

## PR3b review round 2

The round-1 leftover `append(pcm16:)` debug assert for `.finishing` / `.complete` / `.cancelled` / `.failed` was applied. Codex's matching minor is the same change.

### Codex

No leftover minors. The L2 API-key WebSocket probe remains skipped: no STT API key in process env, launchctl, or `com.fluidvoice.stt-credentials`; LLM Keychain `com.fluidvoice.provider-api-keys` / `"xai"` must not be reused; the result is not faked. L4 already exercised `wss://api.x.ai/v1/stt`.

### Claude

- **Connection and URLSession leak on post-`audio.done` transport drop** (`Sources/Fluid/Services/GrokSTT/GrokSTTWebSocketSession.swift`). When the socket dies after `audio.done` with non-empty text, `handleTransportFailure` marks `.complete` and resumes finish waiters without `closeConnection()`. ASRService then `cancel()`s a already-terminal session, so `URLSession` is never `invalidateAndCancel()`'d. One leaked pair per dictation that ends this way. The `recordDone` and done-timeout paths both close correctly. Suggested: call `self.closeConnection()` in the post-done success branch of `handleTransportFailure` before `resumeFinishWaiters(.success(assembled))`.

- **`isGrokSTTSelectable` reads `UserDefaults.standard` instead of the store's injected defaults** (`Sources/Fluid/Persistence/SettingsStore.swift`). The `authMode` default argument hardcodes `UserDefaults.standard.string(forKey: grokSTTAuthModeDefaultsKey)` (`:4594-4596`), while `SettingsStore.grokSTTAuthMode` reads `self.defaults` (`:5962-5966`). A test or configuration that injects a non-standard defaults suite will see the two disagree. `GrokSTTCredentialResolverDependencies.production()` has the same pattern (PR2). Suggested: thread the auth mode in from the caller (or `SettingsStore.shared.grokSTTAuthMode`) rather than reading `UserDefaults.standard` in a default argument.

- **`canActivateVoiceEngine` now performs Keychain / auth.json I/O from a SwiftUI body** (`Sources/Fluid/Persistence/SettingsStore.swift`). `SpeechModel.canActivateVoiceEngine` calls `isGrokSTTSelectable()`, which evaluates `grokSTTCredentialSourceConfigured` → Keychain or `~/.grok/auth.json` I/O. That property is read from `.disabled(...)` in the engine list body (`AISettingsView+SpeechRecognition.swift:475`) on every render. Only the Grok row reaches it. PR2 already calls the same property at `:775` / `:790`. Suggested: cache the credential-source result in `VoiceEngineSettingsViewModel` (refreshed on appear and on auth-mode/key change).

## PR3b review round 3

Blocking/major items applied in this round: remaining created-budget bounds credential resolve and `transport.connect`; URLSession `open()` is cancellation-aware; `timeoutIntervalForResource` is no longer the 20 s connect cap.

### Codex

- **Post-audio.done transport success leaks its connection** (`Sources/Fluid/Services/GrokSTT/GrokSTTWebSocketSession.swift:406`). When transport fails after `audio.done` with assembled text, `handleTransportFailure` marks the session complete and resumes finish waiters without closing the connection. Later `cancel()` treats `.complete` as already terminal and also skips close. Suggested: call `closeConnection()` before returning success and assert the fake connection closes in `testPostDoneTransportErrorWithTextSucceeds`. Same leftover as Claude's round-2 leak note.

- **Selectability bypasses injected settings defaults** (`Sources/Fluid/Persistence/SettingsStore.swift:4589`). `isGrokSTTSelectable`'s default `authMode` reads `UserDefaults.standard` directly, while `SettingsStore` can use an injected defaults suite. Suggested: pass the owning store's auth mode into the gate or inject the defaults source. Same leftover as Claude's round-2 selectable-defaults note.

### Claude

- **URLSession + connection leak on post-`audio.done` transport drop** (`Sources/Fluid/Services/GrokSTT/GrokSTTWebSocketSession.swift`). Carried from round 2; `recordDone` and the done-timeout path both close correctly. Suggested: `self.closeConnection()` in the post-done success branch of `handleTransportFailure` immediately before `resumeFinishWaiters(.success(assembled))`.

- **`append` debug assert can fire on `.failed` / `.cancelled` the pump cannot avoid** (`Sources/Fluid/Services/GrokSTT/GrokSTTWebSocketSession.swift`). GROK-STT-DESIGN only calls append-after-`finish`/`cancel` illegal. The pump's inner frame-drain loop does not re-check `isRunning` / `Task.isCancelled` / `transportError`. A receive-loop `fail()` or MainActor `cancelStreamingSession` between the outer check and an `append` hits `assertionFailure` in Debug. Suggested: re-check those gates inside the inner frame loop, and leave `.failed` a quiet no-op.

## PR3b review round 4

Blocking/major items applied in this round: failed WebSocket upgrades now `close()` the connection (and its URLSession) before rethrowing; the write-only session `credential` field was deleted so the bearer is not retained past request construction.

### Codex

- **Post-audio.done transport success still leaks its connection** (`Sources/Fluid/Services/GrokSTT/GrokSTTWebSocketSession.swift:493`). With assembled text after `audio.done`, the session marks completion and resumes finish waiters without `closeConnection()`. Subsequent `cancel()` sees `.complete`, clears the reference, but intentionally skips invalidating the URLSession. Suggested: call `closeConnection()` on this success path and assert closure in `testPostDoneTransportErrorWithTextSucceeds`. Same leftover as Claude's round-2/3 leak note.

- **Expected transport failure can trigger a Debug assertion** (`Sources/Fluid/Services/GrokSTT/GrokSTTWebSocketSession.swift:141`). `append` asserts for `.failed`, but a receive-loop failure can occur between the pump’s outer transport-error check and its inner append. That normal race can trap Debug builds. Suggested: treat `.failed` as a quiet no-op, or recheck the transport/session gate immediately before every inner-loop append. Same leftover as Claude's round-3 append-assert note.

### Claude

- **DEBUG `append` assert fires on `.failed`, which the pump cannot avoid** (`Sources/Fluid/Services/GrokSTT/GrokSTTWebSocketSession.swift`). `append(pcm16:)` asserts for `.finishing, .complete, .cancelled, .failed` (GrokSTTWebSocketSession.swift:148). GROK-STT-DESIGN only declares append-after-`finish()`/`cancel()` illegal. A mid-stream transport drop is an explicitly *normal* path ("Do not abort PTT. Stop appending."), and `GrokSTTSessionPump.run`'s inner frame-drain loop (GrokSTTSessionPumpGate.swift:72-88) re-checks neither `session.transportError` nor `Task.isCancelled` between appends. A receive-loop `fail()` landing between the outer check and an append trips `assertionFailure` in Debug builds. Carried from round 3 and recorded in review-notes.md; not fixed. Suggested: limit the assert to `.finishing`/`.complete`/`.cancelled` (leave `.failed` a quiet no-op), and re-check `gate.snapshot.transportError` / `session.transportError` / `Task.isCancelled` inside the pump's inner frame loop.

- **Post-`audio.done` transport success leaks the connection and its URLSession** (`Sources/Fluid/Services/GrokSTT/GrokSTTWebSocketSession.swift`). When the socket dies after `audio.done` with non-empty assembled text, `handleTransportFailure` marks `.complete` and resumes finish waiters without calling `closeConnection()` (GrokSTTWebSocketSession.swift:494-505). `cancel()` then treats `.complete` as already-terminal and also skips `connection?.close()`, so the ephemeral `URLSession` is never `invalidateAndCancel()`'d and keeps its delegate alive. The `recordDone` and done-timeout paths both close correctly. Raised in rounds 2 and 3 by both reviewers; still unfixed. Suggested: call `self.closeConnection()` in the post-done success branch immediately before `resumeFinishWaiters(.success(assembled))`, and assert `connection.closed` in `testPostDoneTransportErrorWithTextSucceeds`.

- **REST 429 discards the `Retry-After` header** (`Sources/Fluid/Services/GrokSTT/GrokSTTRESTClient.swift`). `sendMultipart` maps non-200 with `GrokSTTError.fromHTTPStatus(http.statusCode)` (GrokSTTRESTClient.swift:160), never passing the `retryAfter:` argument that `fromHTTPStatus` accepts. A 429 from xAI therefore always surfaces as `.rateLimited(retryAfter: nil)` even when the response carries `Retry-After`, so the user-facing copy can never say how long to wait. Behaviorally acceptable under the design ("Retry button is the backoff, do not auto-loop"), but the parsed value is free. Suggested: read `http.value(forHTTPHeaderField: "Retry-After")`, parse it as `TimeInterval`, and pass it through as `fromHTTPStatus(http.statusCode, retryAfter:)`.

- **Connection leaks if the created-budget timeout wins a photo-finish against a successful connect** (`Sources/Fluid/Services/GrokSTT/GrokSTTWebSocketSession.swift`). In `withCreatedBudget` (GrokSTTWebSocketSession.swift:349), if `transport.connect` returns a live connection at the same instant the budget-sleep task throws `.timeout`, `group.next()` may surface the timeout first; `group.cancelAll()` then cancels an already-completed connect task, so the returned `UncheckedConnection` is dropped without `close()`. `self.connection` was never assigned, so the subsequent `fail(..., close: true)` closes nothing and the URLSessionWebSocketTask plus its ephemeral session leak. Extremely narrow window (requires the two to land in the same instant at the 20 s mark), which is why it is minor. Suggested: in the `catch` of `withCreatedBudget` (or in `connectWithCreatedBudget`), await the connect task's result after `cancelAll()` and `close()` any connection it produced before rethrowing.

## PR3b review round 5

Blocking/major/overbuilt items applied in this round: deleted the unused two-argument `transcribeFinal(_:languageCode:)` 501 stub (not a `TranscriptionProvider` requirement; zero callers) and the dead `grokSTTActivateHint` "Not activatable yet" branch.

### Codex

- **Post-done transport success leaves the connection open** (`Sources/Fluid/Services/GrokSTT/GrokSTTWebSocketSession.swift:493`). When transport fails after `audio.done` with assembled text, the session completes without closing the connection. Later cancellation treats `.complete` as terminal and skips `close()`, potentially leaking the URLSession/delegate pair. Suggested: call `closeConnection()` before resuming success and assert `connection.closed` in the post-done transport test. Same leftover as rounds 2–4.

- **Expected transport failure can trigger a Debug assertion** (`Sources/Fluid/Services/GrokSTT/GrokSTTWebSocketSession.swift:140`). `append` asserts for `.failed`, but the pump checks transport state only before entering its inner frame loop. A normal mid-stream failure between that check and an append can trap Debug builds. Suggested: treat `.failed` as a quiet no-op and recheck cancellation/transport state before each pump append. Same leftover as rounds 3–4.

- **REST 429 responses discard Retry-After** (`Sources/Fluid/Services/GrokSTT/GrokSTTRESTClient.swift:159`). Non-200 responses are mapped from status alone, so `.rateLimited` never receives a server-provided Retry-After value. Suggested: parse the Retry-After header and pass it to `fromHTTPStatus`. Same leftover as Claude's round-4 note.

- **Created-budget photo finish can orphan a connection** (`Sources/Fluid/Services/GrokSTT/GrokSTTWebSocketSession.swift:320`). If the timeout and a successful connection complete together and the timeout result is consumed first, the completed connection value is discarded before it is assigned to `self.connection`, leaving nothing for failure cleanup to close. Suggested: ensure a connection produced during timeout cancellation is explicitly closed before rethrowing. Same leftover as Claude's round-4 photo-finish note.

### Claude

- **Engine card subtitle says "Not active" while the row shows the green "Active" badge** (`Sources/Fluid/UI/AISettingsView+SpeechRecognition.swift`). `speechModelSubtitle(for: .grokSTT)` returns "Grok Speech (xAI) · Not active" whenever a credential source is configured, and it is rendered unconditionally at `:344` — independent of `isActive` (`:326`). Before PR3b `canActivateVoiceEngine` was always false, so Grok could never reach the active state and the string was harmless. Now a user who activates Grok sees the title "Cloud dictation", the subtitle "Grok Speech (xAI) · Not active", and the green "Active" capsule (`:459-465`) at the same time. Cosmetic, but it is the engine card copy the spec calls out as required. Suggested: make the subtitle state-aware — "Needs credentials" when unconfigured, brand/cloud line otherwise, and let the Active badge own activation state.

- **Post-`audio.done` transport-drop success still leaks its connection and URLSession** (`Sources/Fluid/Services/GrokSTT/GrokSTTWebSocketSession.swift`). When the socket dies after `audio.done` with non-empty assembled text, `handleTransportFailure` sets `.complete` and resumes finish waiters without `closeConnection()` (`:493-503`). ASRService then calls `cancel()`, which treats `.complete` as terminal and skips `connection?.close()`. The ephemeral `URLSession` is never `invalidateAndCancel()`'d. Raised in rounds 2, 3, and 4 by both reviewers and deliberately recorded rather than fixed. Suggested: call `self.closeConnection()` immediately before `self.resumeFinishWaiters(.success(assembled))` in the post-done branch, and assert `connection.closed` in `testPostDoneTransportErrorWithTextSucceeds`.

- **DEBUG `append` assert can fire on `.failed`, which the pump cannot avoid** (`Sources/Fluid/Services/GrokSTT/GrokSTTWebSocketSession.swift`). `append(pcm16:)` calls `assertionFailure` for `.finishing, .complete, .cancelled, .failed` (`:146-151`). GROK-STT-DESIGN only declares append-after-`finish()`/`cancel()` illegal; a mid-stream transport drop is an explicitly normal path ("Do not abort PTT. Stop appending."). `GrokSTTSessionPump.run`'s inner frame-drain loop does not re-check `session.transportError` or `Task.isCancelled` between appends. Release is unaffected. Carried from rounds 3 and 4. Suggested: limit the assert to `.finishing`/`.complete`/`.cancelled` and leave `.failed` a quiet no-op, or re-check transport/cancellation inside the pump's inner frame loop.

- **REST 429 discards the `Retry-After` header** (`Sources/Fluid/Services/GrokSTT/GrokSTTRESTClient.swift`). `sendMultipart` maps every non-200 via `GrokSTTError.fromHTTPStatus(http.statusCode)` (`:160`) and never passes the `retryAfter:` parameter. A 429 from xAI therefore always surfaces as `.rateLimited(retryAfter: nil)`. Behaviorally acceptable under the design ("Retry button is the backoff, do not auto-loop"). Carried from round 4. Suggested: read `Retry-After`, parse it as a `TimeInterval`, and pass it through as `fromHTTPStatus(http.statusCode, retryAfter:)`.

- **`isGrokSTTSelectable` reads `UserDefaults.standard` instead of the store's injected defaults** (`Sources/Fluid/Persistence/SettingsStore.swift`). The `authMode` default argument hardcodes `UserDefaults.standard.string(forKey: grokSTTAuthModeDefaultsKey)` (`:4594-4596`), while `SettingsStore.grokSTTAuthMode` reads the instance's `self.defaults`. A test or configuration that injects a non-standard suite will see the selectability gate and the store disagree. `GrokSTTCredentialResolverDependencies.production()` has the identical pattern (PR2). Carried from rounds 2 and 3. Suggested: thread the auth mode in from the caller (or read `SettingsStore.shared.grokSTTAuthMode`) rather than reading `UserDefaults.standard` in a default argument.

- **`canActivateVoiceEngine` performs Keychain / auth.json I/O from a SwiftUI body** (`Sources/Fluid/Persistence/SettingsStore.swift`). PR3b routes `SpeechModel.canActivateVoiceEngine` through `isGrokSTTSelectable()` (`:5350-5356`), which evaluates `grokSTTCredentialSourceConfigured` → Keychain lookup (API-key mode) or a synchronous `~/.grok/auth.json` read (CLI mode). That property is read twice per engine row from the list body (`AISettingsView+SpeechRecognition.swift:475,477`) on every render. Only the Grok row reaches it, but each render does main-thread I/O. Carried from round 2. Suggested: cache the credential-source result in `VoiceEngineSettingsViewModel`, refreshed on appear and on auth-mode / key change.

## PR3b review round 6

Blocking/major/specViolation items applied in this round:

- **API-key WebSocket disabled until probe L2 runs.** L2 was recorded as skipped (no xAI API key on the probe machine) while the API-key socket path was still enabled — an unprobed dictation path. Added `SettingsStore.SpeechModel.grokSTTAPIKeySocketEnabled = false`; `isGrokSTTSelectable` now gates the `.apiKey` auth mode on it, `GrokSTTWebSocketSession` refuses an `.apiKey` credential with a 501 before connecting, and the settings card/Activate hint explain the mode is unavailable. The probe was not faked; CLI-socket (L4 passed) remains enabled. Flip the flag only after L2 actually passes.
- **`append(pcm16:)` no longer traps Debug builds on a retryable mid-stream drop.** The DEBUG assert fired for `.failed` (and could race an Esc `.cancelled`), which the pump cannot avoid between its gate check and an append. The assert is now `assert(!audioDoneSent)` — only an append after `finish()` sent `audio.done` (a real ordering bug, never a race: the pump is joined before `finish()`) asserts. Covered by `testAppendAfterMidStreamTransportFailureIsSafeNoOp`.
- **Post-`audio.done` transport-drop success now closes its connection.** `handleTransportFailure` calls `closeConnection()` after resuming finish waiters with assembled text, and `cancel()` closes the captured connection even from a terminal state (close is idempotent), so the ephemeral URLSession is always `invalidateAndCancel()`'d. Asserted in `testPostDoneTransportErrorWithTextSucceeds`.

### Minors (recorded, not blocking)

- **Engine card subtitle says "Not active" next to the green Active badge** (`Sources/Fluid/UI/AISettingsView+SpeechRecognition.swift`). Same as round 5: `speechModelSubtitle(for: .grokSTT)` returns "· Not active" regardless of activation state while the row shows the Active capsule. Suggested: make the subtitle state-aware and let the badge own activation state.
- **No bound on outbound send while `finish()` waits for `audio.done`** (`Sources/Fluid/Services/GrokSTT/GrokSTTWebSocketSession.swift`). After stop, `sendAudioDone` waits for the serialized sender to drain every queued frame before the `audio.done` text send resolves, with no overall deadline; a stalled `send(data:)` defers to the transport's own timeout. Bounded in practice by the pump's 20-frame queue pause plus URLSession timeouts. Suggested: if this ever bites, wrap the drain in a deadline that fails the session as pre-done (retryable).
