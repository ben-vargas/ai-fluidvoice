@testable import FluidVoice_Debug
import XCTest

final class GrokSTTSpeechModelCatalogTests: XCTestCase {
    func testGrokSTTLandmineFlags() {
        let model = SettingsStore.SpeechModel.grokSTT

        XCTAssertEqual(model.rawValue, "grok-stt")
        XCTAssertEqual(model.displayName, "Grok Speech (xAI)")
        XCTAssertFalse(model.isWhisperModel)
        XCTAssertTrue(model.supportsStreaming)
        XCTAssertTrue(model.isInstalled)
        XCTAssertTrue(model.isCloudEngine)
        XCTAssertFalse(model.hasRemovableLocalArtifacts)
        XCTAssertFalse(model.usesAppleLogo)
        XCTAssertEqual(model.expectedDownloadBytes, 0)
        XCTAssertEqual(model.speedRating, 4)
        XCTAssertEqual(model.accuracyRating, 4)
        XCTAssertEqual(model.badgeText, "Cloud · Experimental")
        XCTAssertEqual(model.provider, .xai)
        XCTAssertEqual(model.brandName, "xAI")
        XCTAssertFalse(model.modelsExistOnDiskEquivalent)
        XCTAssertFalse(model.canActivateVoiceEngine)
        XCTAssertFalse(SettingsStore.SpeechModel.grokSTTCatalogVisible)
        XCTAssertFalse(SettingsStore.SpeechModel.availableModels.contains(.grokSTT))
    }

    func testGrokSTTSettingsCardShowsNeitherDownloadNorDelete() {
        let model = SettingsStore.SpeechModel.grokSTT

        XCTAssertTrue(model.isInstalled)
        XCTAssertFalse(model.showsVoiceEngineDownloadAction)
        XCTAssertFalse(model.showsVoiceEngineDeleteAction)
        XCTAssertFalse(model.usesAppleLogo && model.hasRemovableLocalArtifacts)
    }

    func testGrokSTTAnalyticsDescriptorUsesXAIProvider() {
        XCTAssertEqual(SettingsStore.SpeechModel.grokSTT.provider.rawValue, "xAI")
        let descriptor = SettingsStore.SpeechModel.grokSTT.analyticsDescriptor
        XCTAssertEqual(descriptor.provider, "xai")
        XCTAssertEqual(descriptor.model, "grok-stt")
    }

    func testGrokSTTIsNotSelectableWithoutCatalogAndCredential() {
        XCTAssertFalse(SettingsStore.SpeechModel.isGrokSTTSelectable())
        XCTAssertFalse(
            SettingsStore.SpeechModel.isGrokSTTSelectable(
                catalogVisible: true,
                credentialSourceConfigured: false
            )
        )
        XCTAssertFalse(
            SettingsStore.SpeechModel.isGrokSTTSelectable(
                catalogVisible: false,
                credentialSourceConfigured: true
            )
        )
        XCTAssertTrue(
            SettingsStore.SpeechModel.isGrokSTTSelectable(
                catalogVisible: true,
                credentialSourceConfigured: true
            )
        )
    }
}

private extension SettingsStore.SpeechModel {
    /// Catalog engines with no local artifacts report `modelsExistOnDisk() = false`
    /// on the provider; SpeechModel itself is installed so the card skips Download.
    var modelsExistOnDiskEquivalent: Bool {
        self.isCloudEngine ? false : self.isInstalled
    }
}
