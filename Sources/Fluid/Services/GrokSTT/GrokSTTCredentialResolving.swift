import Foundation

nonisolated protocol GrokSTTCredentialResolving: Sendable {
    /// True when the *selected mode's* credential source is configured
    /// (API-key mode: Keychain key present; CLI-session mode: store readable with a `key`).
    /// Must not become false merely because the token is expired or the network is down.
    var isSourceConfigured: Bool { get }

    func resolveCredential() async throws -> GrokSTTCredential

    /// 401 recovery for CLI sessions: one other unexpired entry. Never refresh. Never used for API keys.
    func resolveCredentialAfterUnauthorized(rejectedBearerFingerprint: String) async throws -> GrokSTTCredential
}
