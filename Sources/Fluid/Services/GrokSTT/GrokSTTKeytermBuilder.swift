import Foundation

nonisolated enum GrokSTTKeytermBuilder {
    static let maxTerms = 100
    static let maxChars = 50

    @MainActor
    static func terms() -> [String] {
        self.terms(
            replacements: SettingsStore.shared.customDictionaryEntries,
            vocabulary: (try? ParakeetVocabularyStore.shared.loadUserBoostTerms()) ?? []
        )
    }

    @MainActor
    static func terms(
        replacements: [SettingsStore.CustomDictionaryEntry],
        vocabulary: [ParakeetVocabularyStore.VocabularyConfig.Term]
    ) -> [String] {
        self.terms(
            replacementTexts: replacements.map(\.replacement),
            vocabularyTexts: vocabulary.map(\.text)
        )
    }

    static func terms(
        replacementTexts: [String],
        vocabularyTexts: [String]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(min(Self.maxTerms, replacementTexts.count + vocabularyTexts.count))

        func appendUnique(_ raw: String) {
            guard result.count < Self.maxTerms else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard trimmed.count <= Self.maxChars else { return }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            result.append(trimmed)
        }

        for text in replacementTexts {
            appendUnique(text)
        }
        for text in vocabularyTexts {
            appendUnique(text)
        }
        return result
    }
}
