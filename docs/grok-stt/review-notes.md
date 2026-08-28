# Grok STT review notes

Minors from review rounds. Do not treat these as open PR work unless a later PR’s spec calls for them.

## PR1 review round 1

### Codex

- **Unsupported engines still advertise voice training** (`Sources/Fluid/Views/AutomaticDictionaryCorrectionOverlay.swift:649`). The Train by Voice action is hidden for cloud engines, but the preceding copy still says users can “teach FluidVoice other pronunciations.” Suggested: make that sentence conditional; for unsupported engines, describe saving the correction as a replacement only.

### Claude

- **Unreachable training-content branch leaves an empty padded panel** (`Sources/Fluid/Views/AutomaticDictionaryCorrectionOverlay.swift`). The “Voice training is unavailable…” explainer and the `if supportsPronunciationTraining` wrapper around the training panel body were dead code (`.training` is only reachable through the hidden button). Also filed as a major/overbuilt finding; the dead code was deleted in the round-1 fix. Recorded here because Claude also filed it as a minor.

- **README advertises an engine no user can select** (`README.md`). The Supported Models row for `Grok Speech (xAI)` includes “(hidden until credentials ship).” PR1 ships with `grokSTTCatalogVisible = false` and `grokSTTActivateEnabled = false`. GROK-STT-DESIGN asks PR1 for a models table row, so this is a judgement call rather than a spec miss. Suggested: move the row to PR3b, or reword the parenthetical to say the engine is not yet available in released builds.
