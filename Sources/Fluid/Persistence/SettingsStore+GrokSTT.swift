import Combine
import Foundation

/// How Grok Speech authenticates. Explicit: an error never switches modes, so billing never changes silently.
nonisolated enum GrokSTTAuthMode: String, CaseIterable, Identifiable, Sendable {
    /// The xAI key saved under AI Providers (pay-as-you-go API billing).
    case apiKey
    /// The signed-in Grok CLI session in `~/.grok/auth.json` (subscription use).
    case grokCLISession

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .apiKey: return "xAI API key"
        case .grokCLISession: return "Grok CLI session"
        }
    }
}

extension SettingsStore {
    nonisolated static let grokSTTAuthModeDefaultsKey = "GrokSTTAuthMode"
    nonisolated static let grokCLIBinaryPathDefaultsKey = "GrokCLIBinaryPath"
    nonisolated static let grokSTTLanguageDefaultsKey = "SelectedGrokSTTLanguageCode"

    nonisolated static func grokSTTAuthMode(fromStoredValue value: String?) -> GrokSTTAuthMode {
        value.flatMap(GrokSTTAuthMode.init(rawValue:)) ?? .apiKey
    }

    /// Until the user picks, Grok Speech uses the saved xAI key, or else a Grok CLI session if one is on disk.
    nonisolated static func grokSTTAuthMode(fromStoredValue value: String?, hasAPIKey: Bool, hasCLISession: Bool) -> GrokSTTAuthMode {
        if let mode = value.flatMap(GrokSTTAuthMode.init(rawValue:)) {
            return mode
        }
        return !hasAPIKey && hasCLISession ? .grokCLISession : .apiKey
    }

    /// Cheap check for a Grok CLI session: the file exists. Parsing it is left to the credential resolver.
    nonisolated static var hasGrokCLISessionFile: Bool {
        let path = GrokCLIAuthStore().resolvePath()
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    var grokSTTAuthMode: GrokSTTAuthMode {
        get {
            Self.grokSTTAuthMode(
                fromStoredValue: UserDefaults.standard.string(forKey: Self.grokSTTAuthModeDefaultsKey),
                hasAPIKey: GrokSTTSharedXAIKeyStore().hasAPIKey,
                hasCLISession: Self.hasGrokCLISessionFile
            )
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.grokSTTAuthModeDefaultsKey)
        }
    }

    /// Saves the default sign-in once Grok Speech starts using it. The credential resolver reads only the saved
    /// choice, and saving it means adding an xAI key later never moves a Grok CLI user onto API billing.
    func saveGrokSTTAuthModeIfUnset() {
        guard UserDefaults.standard.string(forKey: Self.grokSTTAuthModeDefaultsKey) == nil else { return }
        let mode = self.grokSTTAuthMode
        let hasCredential = mode == .apiKey ? GrokSTTSharedXAIKeyStore().hasAPIKey : Self.hasGrokCLISessionFile
        guard hasCredential else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: Self.grokSTTAuthModeDefaultsKey)
    }

    /// Optional absolute path to the `grok` CLI, used only to refresh an expired session.
    var grokCLIBinaryPath: String? {
        get {
            let value = UserDefaults.standard.string(forKey: Self.grokCLIBinaryPathDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        set {
            objectWillChange.send()
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                UserDefaults.standard.set(trimmed, forKey: Self.grokCLIBinaryPathDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.grokCLIBinaryPathDefaultsKey)
            }
        }
    }

    /// xAI language code, or `nil` for Automatic. A first-time user gets English.
    var selectedGrokSTTLanguageCode: String? {
        get {
            guard let stored = UserDefaults.standard.string(forKey: Self.grokSTTLanguageDefaultsKey) else {
                return GrokSTTLanguage.defaultCode
            }
            guard stored != GrokSTTLanguage.automaticCode else { return nil }
            return GrokSTTLanguage.normalized(stored) ?? GrokSTTLanguage.defaultCode
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(
                newValue.flatMap(GrokSTTLanguage.normalized) ?? GrokSTTLanguage.automaticCode,
                forKey: Self.grokSTTLanguageDefaultsKey
            )
        }
    }
}
