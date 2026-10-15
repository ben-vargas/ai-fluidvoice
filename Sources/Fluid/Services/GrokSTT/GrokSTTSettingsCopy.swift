import Foundation

/// Voice Engine copy for Grok Speech (xAI), kept in one place so the settings UI and tests agree.
nonisolated enum GrokSTTSettingsCopy {
    static let badge = "Cloud · Experimental"

    static let cardDescription =
        "Live cloud dictation from xAI. Dictation, file and meeting audio is sent to xAI (api.x.ai/v1/stt), " +
        "so this is opt-in and not local-first."

    static let apiKeyConfigured = "Using the xAI key saved under AI Providers."
    static let apiKeyMissing = "No xAI key yet. Add one under AI Providers (AI Enhancement), then come back to activate."

    static let apiKeyBilling =
        "Billed to your xAI API account at xAI's published speech-to-text rates."

    static let sharedKeyRemoval =
        "Removing the xAI provider under AI Providers also turns off Grok Speech."

    static let cliSessionExperimental =
        "Uses your signed-in Grok CLI session (~/.grok/auth.json), read-only. xAI does not document this token for " +
        "speech-to-text, so it may stop working. FluidVoice never writes that file."

    static let clientKeyDeviation =
        "xAI recommends proxying WebSockets instead of using keys in client apps. FluidVoice sends your own key or " +
        "CLI token directly from this Mac. Don't use a team-shared key."
}
