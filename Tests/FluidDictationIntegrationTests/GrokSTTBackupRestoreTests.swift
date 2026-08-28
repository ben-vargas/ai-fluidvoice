@testable import FluidVoice_Debug
import XCTest

final class GrokSTTBackupRestoreTests: XCTestCase {
    private let selectedSpeechModelKey = "SelectedSpeechModel"

    func testAutomaticGrokLanguageRoundTripsThroughBackupValue() {
        let backupValue = SettingsStore.grokSTTLanguageBackupValue(for: nil)

        XCTAssertEqual(backupValue, "auto")
        XCTAssertNil(SettingsStore.grokSTTLanguageCode(fromBackupValue: backupValue))
    }

    func testForcedGrokLanguageRoundTripsThroughBackupValue() {
        let backupValue = SettingsStore.grokSTTLanguageBackupValue(for: "fil")

        XCTAssertEqual(backupValue, "fil")
        XCTAssertEqual(SettingsStore.grokSTTLanguageCode(fromBackupValue: backupValue), "fil")
        XCTAssertEqual(SettingsStore.grokSTTLanguageCode(fromBackupValue: "tl"), "fil")
    }

    func testOlderBackupPayloadWithoutGrokFieldsStillDecodes() throws {
        let payload = SettingsStore.shared.makeBackupPayload()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(payload)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "selectedGrokSTTLanguageCode")
        object.removeValue(forKey: "grokCLIBinaryPath")
        object.removeValue(forKey: "grokSTTAuthMode")
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SettingsBackupPayload.self, from: stripped)

        XCTAssertNil(decoded.selectedGrokSTTLanguageCode)
        XCTAssertNil(decoded.grokCLIBinaryPath)
        XCTAssertNil(decoded.grokSTTAuthMode)
        XCTAssertEqual(decoded.selectedSpeechModel, payload.selectedSpeechModel)
    }

    func testRestoringGrokSTTWithoutCredentialSourceFallsBackToDefaultModel() {
        XCTAssertTrue(SettingsStore.SpeechModel.grokSTTCatalogVisible)
        XCTAssertFalse(
            SettingsStore.SpeechModel.isGrokSTTSelectable(
                catalogVisible: true,
                credentialSourceConfigured: false
            )
        )

        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: self.selectedSpeechModelKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: self.selectedSpeechModelKey)
            } else {
                defaults.removeObject(forKey: self.selectedSpeechModelKey)
            }
        }

        defaults.set(SettingsStore.SpeechModel.grokSTT.rawValue, forKey: self.selectedSpeechModelKey)

        if SettingsStore.SpeechModel.grokSTTCredentialSourceConfigured {
            XCTAssertEqual(SettingsStore.shared.selectedSpeechModel, .grokSTT)
        } else {
            XCTAssertEqual(SettingsStore.shared.selectedSpeechModel, SettingsStore.SpeechModel.defaultModel)
            XCTAssertNotEqual(SettingsStore.shared.selectedSpeechModel, .grokSTT)
        }
    }
}
