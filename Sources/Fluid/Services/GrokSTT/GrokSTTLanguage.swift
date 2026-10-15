import Foundation

/// Languages xAI speech-to-text accepts as `language`. Automatic omits the parameter.
nonisolated enum GrokSTTLanguage {
    static let automaticCode = "auto"
    static let defaultCode = "en"

    static let codes = [
        "ar", "cs", "da", "nl", "en", "fil", "fr", "de", "hi", "id", "it", "ja", "ko",
        "mk", "ms", "fa", "pl", "pt", "ro", "ru", "es", "sv", "th", "tr", "vi",
    ]

    static var supportedCodesSummary: String {
        self.codes.map { $0.uppercased() }.joined(separator: ", ")
    }

    /// Normalizes a stored or catalog code. Tagalog `tl` is sent as `fil`; unknown codes are dropped.
    static func normalized(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mapped = trimmed == "tl" ? "fil" : trimmed
        return self.codes.contains(mapped) ? mapped : nil
    }

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
