import Foundation

nonisolated protocol GrokSTTCredentialResolving: Sendable {
    /// True when a credential *source* is configured (key present or store readable with a `key`).
    /// Must not become false because the token is expired or the network is down.
    var isSourceConfigured: Bool { get }

    func resolveCredential() async throws -> GrokSTTCredential

    /// 401 recovery for CLI sessions: one other unexpired entry. Never refresh. Never used for API keys.
    func resolveCredentialAfterUnauthorized(rejectedBearerFingerprint: String) async throws -> GrokSTTCredential
}
