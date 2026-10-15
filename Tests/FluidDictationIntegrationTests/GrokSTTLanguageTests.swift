@testable import FluidVoice_Debug
import XCTest

final class GrokSTTLanguageTests: XCTestCase {
    func testNormalizedMapsTagalogAndRejectsUnknownCodes() {
        XCTAssertEqual(GrokSTTLanguage.normalized("tl"), "fil")
        XCTAssertEqual(GrokSTTLanguage.normalized(" EN "), "en")
        XCTAssertNil(GrokSTTLanguage.normalized("xx"))
        XCTAssertNil(GrokSTTLanguage.normalized(GrokSTTLanguage.automaticCode))
    }

    func testWireCodeOmitsAutomatic() {
        XCTAssertNil(GrokSTTLanguage.wireCode(nil))
        XCTAssertEqual(GrokSTTLanguage.wireCode("ja"), "ja")
    }

    func testCodesAreUniqueAndCoverTwentyFiveLanguages() {
        XCTAssertEqual(GrokSTTLanguage.codes.count, 25)
        XCTAssertEqual(Set(GrokSTTLanguage.codes).count, GrokSTTLanguage.codes.count)
    }

    func testAuthModeDefaultsToAPIKey() {
        XCTAssertEqual(SettingsStore.grokSTTAuthMode(fromStoredValue: nil), .apiKey)
        XCTAssertEqual(SettingsStore.grokSTTAuthMode(fromStoredValue: "garbage"), .apiKey)
        XCTAssertEqual(SettingsStore.grokSTTAuthMode(fromStoredValue: "grokCLISession"), .grokCLISession)
    }

    func testUnsetAuthModeUsesSavedKeyThenCLISession() {
        XCTAssertEqual(SettingsStore.grokSTTAuthMode(fromStoredValue: nil, hasAPIKey: true, hasCLISession: true), .apiKey)
        XCTAssertEqual(SettingsStore.grokSTTAuthMode(fromStoredValue: nil, hasAPIKey: false, hasCLISession: true), .grokCLISession)
        XCTAssertEqual(SettingsStore.grokSTTAuthMode(fromStoredValue: nil, hasAPIKey: false, hasCLISession: false), .apiKey)
        XCTAssertEqual(SettingsStore.grokSTTAuthMode(fromStoredValue: "apiKey", hasAPIKey: false, hasCLISession: true), .apiKey)
        XCTAssertEqual(SettingsStore.grokSTTAuthMode(fromStoredValue: "grokCLISession", hasAPIKey: true, hasCLISession: false), .grokCLISession)
    }

    @MainActor
    func testGrokSpeechIsAnOptInCloudEngine() {
        let model = SettingsStore.SpeechModel.grokSTT
        XCTAssertTrue(model.isCloudEngine)
        XCTAssertEqual(model.provider, .xai)
        XCTAssertFalse(SettingsStore.SpeechModel.allCases.filter(\.isCloudEngine).contains { $0 != .grokSTT })
    }
}
