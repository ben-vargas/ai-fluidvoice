@testable import FluidVoice_Debug
import XCTest

final class GrokSTTLanguageSelectionTests: XCTestCase {
    func testAutomaticLanguageOmitsQueryParameter() {
        XCTAssertNil(SettingsStore.grokSTTLanguageCode(fromStoredValue: nil))
        XCTAssertNil(SettingsStore.grokSTTLanguageCode(fromStoredValue: "auto"))
        XCTAssertNil(SettingsStore.grokSTTQueryLanguageParameter(fromStoredValue: nil))
        XCTAssertNil(SettingsStore.grokSTTQueryLanguageParameter(fromStoredValue: "auto"))
    }

    func testFilipinoIsStoredAndSentAsFil() {
        XCTAssertEqual(SettingsStore.grokSTTLanguageCode(fromStoredValue: "fil"), "fil")
        XCTAssertEqual(SettingsStore.grokSTTQueryLanguageParameter(fromStoredValue: "fil"), "fil")
        XCTAssertEqual(VoiceEngineLanguageCatalog.grokSTTLanguageCode(for: "tl"), "fil")
        XCTAssertEqual(SettingsStore.normalizedGrokSTTLanguageCode("tl"), "fil")
        XCTAssertEqual(VoiceEngineLanguageCatalog.grokSTTLanguageDisplayName(forCode: "fil"), "Filipino")
    }

    func testMandarinIsNotInGrokPicker() {
        XCTAssertNil(VoiceEngineLanguageCatalog.grokSTTLanguageCode(for: "zh"))
        XCTAssertNil(VoiceEngineLanguageCatalog.grokSTTLanguage(forCode: "zh"))
        XCTAssertNil(SettingsStore.normalizedGrokSTTLanguageCode("zh"))
        XCTAssertFalse(VoiceEngineLanguageCatalog.grokSTTLanguageCodes.contains("zh"))
        XCTAssertFalse(VoiceEngineLanguageCatalog.grokSTTLanguages.contains { $0.id == "zh" })
    }

    func testGrokPickerContainsTwentyFiveCodesIncludingFilNotTl() {
        let codes = VoiceEngineLanguageCatalog.grokSTTLanguageCodes
        XCTAssertEqual(codes.count, 25)
        XCTAssertEqual(Set(codes).count, 25)
        XCTAssertTrue(codes.contains("fil"))
        XCTAssertFalse(codes.contains("tl"))
        XCTAssertEqual(VoiceEngineLanguageCatalog.grokSTTLanguages.count, 25)
    }

    func testOnboardingRouteCandidatesDoNotIncludeGrok() {
        let english = VoiceEngineLanguage(
            id: "en",
            displayName: "English",
            aliases: [],
            isPopular: true
        )
        let routes = VoiceEngineLanguageCatalog.routes(
            for: english,
            availableModels: SettingsStore.SpeechModel.allCases
        )
        XCTAssertFalse(routes.contains { $0.model == .grokSTT })
        XCTAssertFalse(routes.contains {
            if case .grokSTT = $0.binding { return true }
            return false
        })
    }
}
