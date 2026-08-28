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
        XCTAssertFalse(GrokSTTProvider().modelsExistOnDisk())
        XCTAssertTrue(SettingsStore.SpeechModel.grokSTTCatalogVisible)
        XCTAssertTrue(SettingsStore.SpeechModel.grokSTTActivateEnabled)
        XCTAssertTrue(SettingsStore.SpeechModel.grokSTTCLISocketEnabled)
        XCTAssertTrue(SettingsStore.SpeechModel.availableModels.contains(.grokSTT))
    }

    func testGrokSTTSettingsCardShowsNeitherDownloadNorDelete() {
        let model = SettingsStore.SpeechModel.grokSTT

        XCTAssertTrue(model.isInstalled)
        XCTAssertFalse(model.showsVoiceEngineDeleteAction)
        XCTAssertFalse(model.usesAppleLogo && model.hasRemovableLocalArtifacts)
    }

    func testGrokSTTAnalyticsDescriptorUsesXAIProvider() {
        XCTAssertEqual(SettingsStore.SpeechModel.grokSTT.provider.rawValue, "xAI")
        let descriptor = SettingsStore.SpeechModel.grokSTT.analyticsDescriptor
        XCTAssertEqual(descriptor.provider, "xai")
        XCTAssertEqual(descriptor.model, "grok-stt")
    }

    func testSpeechProviderFilterShowsXAIWhenCatalogVisible() {
        XCTAssertTrue(SettingsStore.SpeechModel.grokSTTCatalogVisible)
        XCTAssertTrue(SpeechProviderFilter.allCases.contains(.xai))
        XCTAssertTrue(SpeechProviderFilter.visibleCases.contains(.xai))
        XCTAssertEqual(
            SpeechProviderFilter.visibleCases.map(\.rawValue),
            ["All", "NVIDIA", "Apple", "Cohere", "OpenAI", "xAI"]
        )
    }

    func testLocalSpeechEnginesAreNotCloudEngines() {
        let localEngines: [SettingsStore.SpeechModel] = [
            .parakeetTDT,
            .parakeetTDTv2,
            .parakeetRealtime,
            .qwen3Asr,
            .cohereTranscribeSixBit,
            .nemotronOffline,
            .nemotronStreaming,
            .nemotronStreaming320,
            .appleSpeech,
            .appleSpeechAnalyzer,
            .whisperTiny,
            .whisperBase,
            .whisperSmall,
            .whisperMedium,
            .whisperLargeTurbo,
            .whisperLarge,
        ]
        for model in localEngines {
            XCTAssertFalse(model.isCloudEngine, "\(model.rawValue) must stay local")
        }
        XCTAssertTrue(SettingsStore.SpeechModel.grokSTT.isCloudEngine)
    }

    func testGrokSTTIsNotSelectableWithoutCatalogActivateAndCredential() {
        XCTAssertFalse(
            SettingsStore.SpeechModel.isGrokSTTSelectable(
                catalogVisible: true,
                activateEnabled: true,
                credentialSourceConfigured: false
            )
        )
        XCTAssertFalse(
            SettingsStore.SpeechModel.isGrokSTTSelectable(
                catalogVisible: false,
                activateEnabled: true,
                credentialSourceConfigured: true
            )
        )
        XCTAssertFalse(
            SettingsStore.SpeechModel.isGrokSTTSelectable(
                catalogVisible: true,
                activateEnabled: false,
                credentialSourceConfigured: true
            )
        )
        XCTAssertTrue(
            SettingsStore.SpeechModel.isGrokSTTSelectable(
                catalogVisible: true,
                activateEnabled: true,
                credentialSourceConfigured: true
            )
        )
        XCTAssertFalse(
            SettingsStore.SpeechModel.isGrokSTTSelectable(
                catalogVisible: true,
                activateEnabled: true,
                credentialSourceConfigured: false
            )
        )
        XCTAssertFalse(
            SettingsStore.SpeechModel.isGrokSTTSelectable(
                catalogVisible: true,
                activateEnabled: true,
                credentialSourceConfigured: true,
                cliSocketEnabled: false,
                authMode: .grokCLISession
            )
        )
        XCTAssertTrue(
            SettingsStore.SpeechModel.isGrokSTTSelectable(
                catalogVisible: true,
                activateEnabled: true,
                credentialSourceConfigured: true,
                cliSocketEnabled: false,
                authMode: .apiKey
            )
        )
    }

    func testLocalSpeechModelResolutionDoesNotEvaluateGrokCredentialAvailability() {
        let localRawValues = SettingsStore.SpeechModel.allCases
            .filter { $0 != .grokSTT }
            .map(\.rawValue)
        XCTAssertFalse(localRawValues.isEmpty)
        for rawValue in localRawValues {
            var evaluated = false
            let resolved = SettingsStore.SpeechModel.resolvedSpeechModel(
                rawValue: rawValue,
                isGrokSelectable: {
                    evaluated = true
                    return true
                }()
            )
            XCTAssertFalse(evaluated, "credential gate ran for \(rawValue)")
            XCTAssertEqual(resolved.rawValue, rawValue)
        }

        var grokEvaluated = false
        _ = SettingsStore.SpeechModel.resolvedSpeechModel(
            rawValue: SettingsStore.SpeechModel.grokSTT.rawValue,
            isGrokSelectable: {
                grokEvaluated = true
                return false
            }()
        )
        XCTAssertTrue(grokEvaluated, "Grok raw values must still evaluate the selectability gate")
    }
}
