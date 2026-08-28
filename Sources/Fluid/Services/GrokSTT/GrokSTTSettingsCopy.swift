import Foundation

/// Required Voice Engine copy for Grok Speech (xAI). Experimental badge, billing, and
/// the documented client-key deviation live here so settings UI and tests share one source.
nonisolated enum GrokSTTSettingsCopy {
    static let experimentalBadge = "Cloud · Experimental"

    static let cardDescription =
        "Cloud. Your microphone audio is sent to xAI for transcription (wss://api.x.ai/v1/stt). This is opt-in and is not local-first."

    static let apiKeyBilling =
        "API key (documented): billed at xAI’s published rates (streaming ~$0.20/hour, REST ~$0.10/hour as of 2026-08-27)."

    static let cliSessionExperimental =
        "Grok CLI session (experimental, undocumented): uses a read-only ~/.grok/auth.json. " +
        "xAI does not publish that this token is valid for STT; it may stop working. " +
        "Billing/quota for this path is unknown. FluidVoice never writes that file."

    static let clientKeyDeviation =
        "xAI’s docs tell developers to proxy WebSockets and not put keys in clients. " +
        "FluidVoice presents your key or your CLI token from this Mac app. Do not paste a team-shared key."

    static let sttKeyIsolation =
        "This key is used only for speech-to-text. It is not the xAI key under AI Enhancement."

    static let needsCredentialsSubtitle = "Grok Speech (xAI) · Needs credentials"
    static let configuredSubtitle = "Grok Speech (xAI)"

    /// Activation state belongs on the Active badge, not the subtitle.
    static func engineSubtitle(needsCredentials: Bool) -> String {
        needsCredentials ? self.needsCredentialsSubtitle : self.configuredSubtitle
    }
}
