import Foundation

extension MeetingBackendID {
    /// Grok Speech (xAI) through the in-pipeline workflow, which transcribes with the
    /// selected voice engine. Chosen automatically while Grok is the selected engine.
    static let grokSTT = MeetingBackendID(rawValue: "hosted-grok-stt-legacy-v1")
}

/// Runs the same in-pipeline workflow as `MeetingLegacyCompatibilityBackend` (local
/// diarization, echo policy, checkpoints) but declares Grok's languages and hosted
/// execution. The legacy backend is English-only because its local model is.
///
/// A canonical-evidence Grok backend can replace this later without touching the pipeline.
@MainActor
final class GrokMeetingTranscriptionBackend: MeetingTranscriptionBackend {
    static let descriptor = MeetingBackendDescriptor(
        id: .grokSTT,
        version: "1",
        execution: .hosted,
        supportedLanguageCodes: Set(GrokSTTLanguage.codes),
        supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
        supportedFinalPrecisions: [.utterance],
        resultContract: .legacyResult,
        knownLimits: [
            "Meeting audio is uploaded to xAI for transcription; speaker labels stay local.",
            "Returns the existing MeetingProcessingResult directly; it emits no canonical final text-unit evidence.",
        ]
    )

    var descriptor: MeetingBackendDescriptor {
        Self.descriptor
    }

    private let legacyExecutor: MeetingLegacyBackendExecutor

    init(legacyExecutor: @escaping MeetingLegacyBackendExecutor) {
        self.legacyExecutor = legacyExecutor
    }

    func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
        guard GrokSTTLanguage.normalized(request.session.languageCode) != nil else {
            throw MeetingBackendError.unsupportedLanguage(
                backend: self.descriptor.id,
                languageCode: request.session.languageCode
            )
        }
        let plan = MeetingBackendPlan(request: request, descriptor: self.descriptor)
        guard !plan.trackKindsByID.isEmpty else {
            throw MeetingBackendError.unsupportedTrackTopology(backend: self.descriptor.id)
        }
        return plan
    }

    func execute(
        plan: MeetingBackendPlan,
        manifest: MeetingAnalysisManifest?,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingBackendOutcome {
        try .legacyCompatibility(await self.legacyExecutor(plan.request, progress))
    }
}
