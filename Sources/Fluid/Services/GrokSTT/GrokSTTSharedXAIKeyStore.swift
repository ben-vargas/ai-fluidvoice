import Foundation

nonisolated protocol GrokSTTAPIKeyStoring: Sendable {
    func loadAPIKey() async -> String?
    @MainActor var hasAPIKey: Bool { get }
}

/// Grok Speech reuses the xAI key saved under AI Providers, so one key covers
/// transcription and text cleanup. Removing the xAI provider removes this key too.
nonisolated struct GrokSTTSharedXAIKeyStore: GrokSTTAPIKeyStoring {
    static let providerID = "xai"

    func loadAPIKey() async -> String? {
        await MainActor.run { Self.currentKey() }
    }

    @MainActor
    var hasAPIKey: Bool {
        Self.currentKey() != nil
    }

    @MainActor
    static func currentKey() -> String? {
        let key = SettingsStore.shared.getAPIKey(for: self.providerID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { return nil }
        return key
    }
}
