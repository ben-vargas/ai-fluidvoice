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
