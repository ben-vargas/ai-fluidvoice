import Foundation

/// Languages xAI speech-to-text (`grok-voice-transcribe-2.0`) lists for `language`, as of
/// November 2026: https://docs.x.ai/developers/model-capabilities/audio/speech-to-text
/// Automatic omits the parameter and lets xAI detect the language.
nonisolated enum GrokSTTLanguage {
    static let automaticCode = "auto"
    static let defaultCode = "en"

    static let codes = [
        "ar", "bs", "bg", "yue", "ca", "zh", "hr", "cs", "da", "nl", "en", "fil", "fi",
        "fr", "de", "el", "hi", "hu", "id", "it", "ja", "ko", "mk", "ms", "nb", "fa",
        "pl", "pt", "ro", "ru", "sk", "es", "sv", "th", "tr", "uk", "ur", "vi",
    ]

    static var supportedCodesSummary: String {
        self.codes.map { $0.uppercased() }.joined(separator: ", ")
    }

    /// Normalizes a stored or catalog code. Tagalog `tl` is sent as `fil` and Norwegian `no`
    /// as `nb`; unknown codes are dropped.
    static func normalized(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mapped = self.aliases[trimmed] ?? trimmed
        return self.codes.contains(mapped) ? mapped : nil
    }

    private static let aliases = ["tl": "fil", "no": "nb"]

    /// Wire value for the socket query and REST form. `nil` (Automatic) omits the parameter.
    static func wireCode(_ code: String?) -> String? {
        guard let code else { return nil }
        return self.normalized(code)
    }

    static func displayName(for code: String?) -> String {
        guard let code else { return "Automatic" }
        let localized = Locale.current.localizedString(forLanguageCode: code)
            ?? Locale(identifier: "en_US").localizedString(forLanguageCode: code)
        return localized ?? code
    }
}
