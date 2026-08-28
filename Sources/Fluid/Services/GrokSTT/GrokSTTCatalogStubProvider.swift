import Foundation

/// PR1 catalog-hidden stand-in. Selected Grok Speech is supposed to fall back in
/// `selectedSpeechModel`; this stub must not be `isReady == false` (that path
/// returns silent `""` from `ASRService.stop`). Transcribe methods trap if hit.
final class GrokSTTCatalogStubProvider: TranscriptionProvider {
    let name = "Grok Speech (xAI)"
    let isAvailable = true
    let isReady = true
    let prefersNativeFileTranscription = true
    let shouldClearCacheAfterCancellation = false

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        _ = progressHandler
        self.trapIfSelectedWhileCatalogHidden("prepare")
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        _ = samples
        self.trapIfSelectedWhileCatalogHidden("transcribe")
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        _ = samples
        self.trapIfSelectedWhileCatalogHidden("transcribeStreaming")
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        _ = samples
        self.trapIfSelectedWhileCatalogHidden("transcribeFinal")
    }

    func transcribeDictionaryTraining(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        _ = samples
        self.trapIfSelectedWhileCatalogHidden("transcribeDictionaryTraining")
    }

    func transcribeFile(at fileURL: URL) async throws -> ASRTranscriptionResult {
        _ = fileURL
        self.trapIfSelectedWhileCatalogHidden("transcribeFile")
    }

    func modelsExistOnDisk() -> Bool { false }

    func clearCache() async throws {}

    private func trapIfSelectedWhileCatalogHidden(_ operation: String) -> Never {
        preconditionFailure(
            "Grok Speech (xAI) \(operation) is not available while the catalog is hidden. " +
                "selectedSpeechModel should have fallen back to the default local engine."
        )
    }
}
