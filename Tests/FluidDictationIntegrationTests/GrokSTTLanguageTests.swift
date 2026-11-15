@testable import FluidVoice_Debug
import XCTest

final class GrokSTTLanguageTests: XCTestCase {
    func testNormalizedMapsTagalogAndRejectsUnknownCodes() {
        XCTAssertEqual(GrokSTTLanguage.normalized("tl"), "fil")
        XCTAssertEqual(GrokSTTLanguage.normalized("no"), "nb")
        XCTAssertEqual(GrokSTTLanguage.normalized(" EN "), "en")
        XCTAssertNil(GrokSTTLanguage.normalized("xx"))
        XCTAssertNil(GrokSTTLanguage.normalized(GrokSTTLanguage.automaticCode))
    }

    func testWireCodeOmitsAutomatic() {
        XCTAssertNil(GrokSTTLanguage.wireCode(nil))
        XCTAssertEqual(GrokSTTLanguage.wireCode("ja"), "ja")
    }

    func testCodesAreUniqueAndCoverXAIsThirtyEightLanguages() {
        XCTAssertEqual(GrokSTTLanguage.codes.count, 38)
        XCTAssertEqual(Set(GrokSTTLanguage.codes).count, GrokSTTLanguage.codes.count)
        XCTAssertTrue(Set(GrokSTTLanguage.codes).isSuperset(of: ["en", "uk", "bg", "fi", "el", "zh", "yue", "nb"]))
        XCTAssertEqual(GrokSTTSettingsCopy.languageSupport, "38 Languages (Select or Auto)")
        // Every code needs a name for the language menu.
        for code in GrokSTTLanguage.codes {
            XCTAssertNotEqual(GrokSTTLanguage.displayName(for: code), code, "No display name for \(code)")
        }
    }

    @MainActor
    func testBackupCarriesSavedGrokSettingsAndRestoreSkipsWhatItCannotUse() {
        let defaults = UserDefaults.standard
        let keys = [
            SettingsStore.grokSTTAuthModeDefaultsKey,
            SettingsStore.grokCLIBinaryPathDefaultsKey,
            SettingsStore.grokSTTLanguageDefaultsKey,
        ]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let settings = SettingsStore.shared

        keys.forEach(defaults.removeObject(forKey:))
        XCTAssertEqual(settings.grokSTTBackupSettings, GrokSTTBackupSettings())

        settings.grokSTTAuthMode = .grokCLISession
        settings.grokCLIBinaryPath = " /opt/homebrew/bin/grok "
        settings.selectedGrokSTTLanguageCode = nil
        let backup = settings.grokSTTBackupSettings
        XCTAssertEqual(backup, GrokSTTBackupSettings(
            authMode: "grokCLISession",
            cliBinaryPath: "/opt/homebrew/bin/grok",
            languageCode: GrokSTTLanguage.automaticCode
        ))
        XCTAssertEqual(settings.makeBackupPayload().grokSTT, backup)

        // The backup survives a JSON round trip, and a backup without the field still decodes.
        let data = try? JSONEncoder().encode(backup)
        XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(GrokSTTBackupSettings.self, from: $0) }, backup)

        keys.forEach(defaults.removeObject(forKey:))
        settings.restoreGrokSTT(backup)
        XCTAssertEqual(settings.grokSTTBackupSettings, backup)

        // Unknown or absent values leave this Mac's settings alone.
        settings.selectedGrokSTTLanguageCode = "de"
        settings.restoreGrokSTT(GrokSTTBackupSettings(authMode: "someFutureMode", cliBinaryPath: nil, languageCode: "xx"))
        XCTAssertEqual(defaults.string(forKey: SettingsStore.grokSTTAuthModeDefaultsKey), "grokCLISession")
        XCTAssertEqual(settings.grokCLIBinaryPath, "/opt/homebrew/bin/grok")
        XCTAssertEqual(settings.selectedGrokSTTLanguageCode, "de")
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
