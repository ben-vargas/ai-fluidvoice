@testable import FluidVoice_Debug
import XCTest

final class GrokSTTLanguageSelectionTests: XCTestCase {
    func testAutomaticLanguageOmitsQueryParameter() {
        XCTAssertNil(SettingsStore.grokSTTLanguageCode(fromStoredValue: nil))
        XCTAssertNil(SettingsStore.grokSTTLanguageCode(fromStoredValue: "auto"))
        XCTAssertNil(SettingsStore.grokSTTQueryLanguageParameter(fromStoredValue: nil))
        XCTAssertNil(SettingsStore.grokSTTQueryLanguageParameter(fromStoredValue: "auto"))
    }

    func testMissingStoredLanguageDefaultsToEnglish() {
        XCTAssertEqual(SettingsStore.defaultGrokSTTLanguageCode, "en")
        XCTAssertEqual(SettingsStore.resolvedGrokSTTLanguageCode(storedObject: nil), "en")
        XCTAssertNil(SettingsStore.resolvedGrokSTTLanguageCode(storedObject: "auto"))
        XCTAssertEqual(SettingsStore.resolvedGrokSTTLanguageCode(storedObject: "en"), "en")
        XCTAssertEqual(SettingsStore.resolvedGrokSTTLanguageCode(storedObject: "fil"), "fil")
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
        XCTAssertEqual(
            codes,
            [
                "ar", "cs", "da", "nl", "en", "fil", "fr", "de", "hi",
                "id", "it", "ja", "ko", "mk", "ms", "fa", "pl", "pt",
                "ro", "ru", "es", "sv", "th", "tr", "vi",
            ]
        )
        XCTAssertEqual(codes.count, 25)
        XCTAssertEqual(Set(codes).count, 25)
        XCTAssertTrue(codes.contains("fil"))
        XCTAssertFalse(codes.contains("tl"))
        XCTAssertFalse(codes.contains("zh"))
        XCTAssertEqual(VoiceEngineLanguageCatalog.grokSTTLanguages.count, 25)
    }

    func testRESTSendsFilAndNeverTl() async throws {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 200, json: ["text": "ok"])
        let client = GrokSTTRESTClient(resolver: RecordingGrokSTTResolver(), http: http)
        _ = try await client.transcribePCM([0.1, 0.2], languageCode: "fil")
        let body = String(decoding: http.requests[0].httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"language\""))
        XCTAssertTrue(body.contains("fil"))
        XCTAssertFalse(body.contains("\r\n\r\ntl\r\n"))
        XCTAssertFalse(body.contains("name=\"language\"\r\n\r\ntl"))
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
