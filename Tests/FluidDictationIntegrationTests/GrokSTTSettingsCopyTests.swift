@testable import FluidVoice_Debug
import XCTest

final class GrokSTTSettingsCopyTests: XCTestCase {
    func testExperimentalBadgeAndCardDescription() {
        let model = SettingsStore.SpeechModel.grokSTT
        XCTAssertEqual(model.badgeText, GrokSTTSettingsCopy.experimentalBadge)
        XCTAssertEqual(model.badgeText, "Cloud · Experimental")
        XCTAssertEqual(model.cardDescription, GrokSTTSettingsCopy.cardDescription)
        XCTAssertTrue(model.cardDescription.contains("wss://api.x.ai/v1/stt"))
        XCTAssertTrue(model.cardDescription.contains("opt-in"))
        XCTAssertTrue(model.cardDescription.localizedCaseInsensitiveContains("not local-first"))
    }

    func testRequiredBillingAndDeviationParagraphs() {
        XCTAssertTrue(GrokSTTSettingsCopy.apiKeyBilling.contains("$0.20"))
        XCTAssertTrue(GrokSTTSettingsCopy.apiKeyBilling.contains("$0.10"))
        XCTAssertTrue(GrokSTTSettingsCopy.cliSessionExperimental.localizedCaseInsensitiveContains("experimental"))
        XCTAssertTrue(GrokSTTSettingsCopy.cliSessionExperimental.contains("~/.grok/auth.json"))
        XCTAssertTrue(GrokSTTSettingsCopy.cliSessionExperimental.contains("never writes"))
        XCTAssertTrue(GrokSTTSettingsCopy.cliSessionExperimental.localizedCaseInsensitiveContains("undocumented"))
        XCTAssertTrue(GrokSTTSettingsCopy.clientKeyDeviation.contains("proxy WebSockets"))
        XCTAssertTrue(GrokSTTSettingsCopy.clientKeyDeviation.contains("Do not paste a team-shared key"))
        XCTAssertTrue(GrokSTTSettingsCopy.sttKeyIsolation.contains("not the xAI key under AI Enhancement"))
    }

    func testEngineSubtitleDoesNotSayNotActive() {
        XCTAssertEqual(
            GrokSTTSettingsCopy.engineSubtitle(needsCredentials: true),
            "Grok Speech (xAI) · Needs credentials"
        )
        XCTAssertEqual(
            GrokSTTSettingsCopy.engineSubtitle(needsCredentials: false),
            "Grok Speech (xAI)"
        )
        XCTAssertFalse(GrokSTTSettingsCopy.engineSubtitle(needsCredentials: false).contains("Not active"))
        XCTAssertFalse(GrokSTTSettingsCopy.engineSubtitle(needsCredentials: true).contains("Not active"))
    }

    func testCatalogAndActivateRemainEnabledForPR5() {
        XCTAssertTrue(SettingsStore.SpeechModel.grokSTTCatalogVisible)
        XCTAssertTrue(SettingsStore.SpeechModel.grokSTTActivateEnabled)
        XCTAssertTrue(SettingsStore.SpeechModel.grokSTTCLISocketEnabled)
        XCTAssertFalse(SettingsStore.SpeechModel.grokSTTAPIKeySocketEnabled)
        XCTAssertTrue(SettingsStore.SpeechModel.availableModels.contains(.grokSTT))
        XCTAssertTrue(SettingsStore.SpeechModel.grokSTT.supportsStreaming)
        XCTAssertFalse(GrokSTTProvider().modelsExistOnDisk())
    }
}
