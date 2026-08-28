@testable import FluidVoice_Debug
import XCTest

final class GrokSTTBackupRestoreTests: XCTestCase {
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
        XCTAssertFalse(SettingsStore.SpeechModel.grokSTTActivateEnabled)
        XCTAssertFalse(
            SettingsStore.SpeechModel.isGrokSTTSelectable(
                catalogVisible: true,
                activateEnabled: false,
                credentialSourceConfigured: false
            )
        )
        XCTAssertFalse(
            SettingsStore.SpeechModel.isGrokSTTSelectable(
                catalogVisible: true,
                activateEnabled: false,
                credentialSourceConfigured: true
            )
        )

        XCTAssertEqual(
            SettingsStore.SpeechModel.resolvedSpeechModel(
                rawValue: SettingsStore.SpeechModel.grokSTT.rawValue,
                isGrokSelectable: false
            ),
            SettingsStore.SpeechModel.defaultModel
        )
        XCTAssertNotEqual(
            SettingsStore.SpeechModel.resolvedSpeechModel(
                rawValue: SettingsStore.SpeechModel.grokSTT.rawValue,
                isGrokSelectable: false
            ),
            .grokSTT
        )
        XCTAssertEqual(
            SettingsStore.SpeechModel.resolvedSpeechModel(
                rawValue: SettingsStore.SpeechModel.grokSTT.rawValue,
                isGrokSelectable: true
            ),
            .grokSTT
        )
    }
}
