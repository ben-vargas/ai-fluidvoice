# FluidVoice Plus

**FluidVoice Plus is a personal fork of [FluidVoice](https://github.com/altic-dev/FluidVoice) that adds cloud speech-to-text through Grok Speech (xAI).**

Upstream FluidVoice is a local-first macOS dictation app, and it intentionally ships on-device speech models only. FluidVoice Plus keeps all of that and adds one opt-in cloud engine. It is not affiliated with or endorsed by FluidVoice or Altic, and none of these changes are proposed upstream.

For everything that isn't covered here (features, settings, local models, building from source), see the upstream [README](../README.md).

## What's different from upstream

| | Upstream FluidVoice | FluidVoice Plus |
| --- | --- | --- |
| Speech engines | On-device only (Parakeet, Nemotron, Cohere, Apple Speech, Whisper) | All of those, plus **Grok Speech (xAI)** as an opt-in cloud engine |
| Where audio goes | Stays on your Mac | Stays on your Mac, unless you select Grok Speech. Then dictation, file, meeting and local-API audio is sent to xAI. |
| App name and bundle ID | FluidVoice, `com.FluidApp.app` | FluidVoice Plus, `com.FluidApp.app.plus`. It installs next to the official app, with its own settings and permissions. |
| Analytics | PostHog key included | PostHog key removed from the build, so no usage analytics are sent |
| Updates | Built-in updater installs upstream releases | Updated by rebuilding from this branch. The built-in updater can't replace FluidVoice Plus, because upstream releases have a different signing team and bundle ID. Turn off automatic update checks in Settings to hide the offers. |

## Grok Speech

Pick **Grok Speech (xAI)** under Voice Engine. It is never a default or an onboarding suggestion.

- **Live dictation** streams over xAI's WebSocket, with interim text in the preview. When you stop, it waits for xAI's final transcript. If the socket fails, the whole recording is uploaded once over REST.
- **Files, meetings and the local API** use xAI's REST endpoint. Meetings get the final Grok transcript; speaker labels still come from the local diarizer, and live meeting captions still use the local engine.
- **The same pipeline as every other engine.** Grok text goes through filler removal, Custom Dictionary, spoken punctuation, AI cleanup styles, history and typing, exactly like a local model. Custom Dictionary terms are also sent to xAI as keyterms, which helps with names.
- **Two ways to sign in, chosen under the Grok row.** You can use the **xAI API key** saved under AI Providers (pay-as-you-go API billing), or your **Grok CLI session** (`~/.grok/auth.json`, read-only, refreshed with the `grok` CLI). FluidVoice Plus never switches between them on its own, so billing never changes silently.
- **Failed dictations aren't lost.** The audio is kept in memory for 15 minutes behind a Retry / Dismiss panel.
- **Languages:** Automatic or a fixed language from xAI's supported list.

How it is built, which upstream files it touches, and the deferred work are in [docs/grok-stt/REIMPLEMENTATION.md](../docs/grok-stt/REIMPLEMENTATION.md).

## Building and installing

```bash
scripts/build-plus.sh
```

The script builds the Release configuration, signs it with the first Apple Development identity in your keychain, and installs `/Applications/FluidVoice Plus.app`. Your team ID is read from the certificate and passed only on the `xcodebuild` command line, so it never ends up in the project file or in git. If the keychain holds several teams, set `FLUIDVOICE_DEVELOPMENT_TEAM`. Quit FluidVoice Plus before rebuilding.

For a Debug build with full diagnostic logging, use the upstream `./build.sh`. It produces a separate "FluidVoice Debug" app.

## Branches

- **`plus`** (the default branch): upstream plus the Grok Speech work. FluidVoice Plus is built from this branch.
- **`main`**: an exact mirror of upstream `main`, with no fork changes, so it always fast-forwards.

Each upstream release is picked up by fast-forwarding `main` and rebasing `plus` onto it. The Grok work lives almost entirely in new files, and it touches upstream code in only a handful of small hooks, so rebases stay cheap.

## License

GPLv3, the same as upstream. See [LICENSE](../LICENSE).
