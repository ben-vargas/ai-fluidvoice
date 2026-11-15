import Foundation

extension MeetingBackendID {
    /// Grok Speech (xAI) word-timed transcription with local Nemotron-3 speaker detection, on
    /// upstream's canonical meeting pipeline.
    static let grokSTTNemotron = MeetingBackendID(rawValue: "hosted-grok-stt-nemotron-3-v1")
}

/// Which backend, if any, Grok uses for a meeting. `nil` leaves the meeting to upstream's choice.
nonisolated enum GrokMeetingBackends {
    /// Languages both xAI and upstream's canonical pipeline (Parakeet v3's set) accept.
    static var canonicalLanguageCodes: Set<String> {
        VoiceEngineLanguageCatalog.parakeetV3LanguageIDs.filter { GrokSTTLanguage.normalized($0) != nil }
    }

    /// The canonical backend needs the local Nemotron model, which is Apple Silicon only. Elsewhere,
    /// and for a Grok language outside the canonical set, Grok keeps the in-pipeline workflow.
    static func backendID(languageCode: String, selectedModel: SettingsStore.SpeechModel) -> MeetingBackendID? {
        guard GrokMeetingTranscriptionBackend.handles(languageCode: languageCode, selectedModel: selectedModel) else { return nil }
        #if arch(arm64)
        if self.canonicalLanguageCodes.contains(languageCode) { return .grokSTTNemotron }
        #endif
        return .grokSTT
    }

    /// The pipeline's question: the backend for the saved voice engine, where that may be followed.
    static func backendIDForSavedEngine(languageCode: String, selectedModel: SettingsStore.SpeechModel) -> MeetingBackendID? {
        guard GrokSTTSavedEngine.isFollowed else { return nil }
        return self.backendID(languageCode: languageCode, selectedModel: selectedModel)
    }

    /// The canonical pipeline prepares the Nemotron model, and trusts text-overlap echo verdicts,
    /// only for backends it knows diarize with Nemotron.
    static func diarizesWithNemotron(_ id: MeetingBackendID) -> Bool {
        id == .grokSTTNemotron
    }

    /// The frozen request names a local model because upstream's planner only accepts those.
    /// A saved attempt should say what actually transcribed it.
    static func recordedASRModel(for id: MeetingBackendID) -> String? {
        id == .grokSTTNemotron ? SettingsStore.SpeechModel.grokSTT.rawValue : nil
    }
}

/// Upstream's canonical meeting backend with one part exchanged: the speech step. Epoch order,
/// audio materialization, speaker assignment, units and coverage receipts are all
/// `MeetingParakeetNemotronBackend`'s, run unchanged through a runtime whose ASR session uploads
/// each epoch to xAI and returns its word timings. Speaker detection stays local.
///
/// It has its own identity so a saved attempt, and the evidence it produced, say that the audio
/// was transcribed by xAI and not on the Mac.
@MainActor
final class GrokMeetingNemotronBackend: MeetingTranscriptionBackend {
    // Explicitly nonisolated, as upstream's backends are (swiftlang/swift#88036).
    nonisolated deinit {}

    static let descriptor = MeetingBackendDescriptor(
        id: .grokSTTNemotron,
        version: "1",
        execution: .hosted,
        supportedLanguageCodes: GrokMeetingBackends.canonicalLanguageCodes,
        supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
        supportedFinalPrecisions: [.word, .utterance],
        resultContract: .canonicalEvidence,
        knownLimits: [
            "Meeting audio is uploaded to xAI for transcription; speaker detection stays local.",
            "Word timings are xAI's. Text that comes back without them becomes one utterance covering its stretch of audio.",
            "A failed upload fails the whole attempt so it can be retried; no partial transcript is published.",
            "Local Nemotron model must be installed before planning.",
        ],
        analysisSampleRate: 16_000
    )

    var descriptor: MeetingBackendDescriptor {
        Self.descriptor
    }

    private let local: MeetingParakeetNemotronBackend
    private let failures: GrokMeetingUploadFailures

    init(
        localRuntimeFactory: @escaping MeetingParakeetNemotronRuntimeFactory,
        modelLocator: any MeetingNemotronModelLocating = MeetingNemotronModelLocator(),
        materializer: any MeetingEpochAudioMaterializing = MeetingEpochAudioMaterializer(),
        transcriber: GrokMeetingASRSession.Transcriber? = nil,
        keyterms: @escaping @Sendable () async -> [String] = { await GrokSTTKeytermBuilder.terms() },
        maxRequestSamples: Int? = nil
    ) {
        let failures = GrokMeetingUploadFailures()
        self.failures = failures
        self.local = MeetingParakeetNemotronBackend(
            runtimeFactory: { request in
                GrokMeetingRuntime(
                    local: try localRuntimeFactory(request),
                    transcriber: transcriber ?? GrokMeetingASRSession.restTranscriber(),
                    keyterms: keyterms,
                    failures: failures,
                    maxRequestSamples: maxRequestSamples
                )
            },
            modelLocator: modelLocator,
            materializer: materializer
        )
    }

    func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
        guard self.descriptor.supportedLanguageCodes.contains(request.session.languageCode) else {
            throw MeetingBackendError.unsupportedLanguage(
                backend: self.descriptor.id,
                languageCode: request.session.languageCode
            )
        }
        // Upstream's planner checks the request and finds the Nemotron model. Its plan carries
        // its own identity, so the plan returned here is rebuilt under this backend's.
        _ = try self.local.plan(request)
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
        self.failures.reset()
        let outcome = try await self.local.execute(plan: plan, manifest: manifest, progress: progress)
        // Upstream records a failed epoch and carries on, which suits a local model. A failed
        // upload is different: the audio is fine and a retry will work, so fail the attempt.
        if let failure = self.failures.first { throw failure }
        guard case let .canonicalEvidence(bundle) = outcome else {
            throw MeetingBackendError.outcomeContractMismatch(backend: self.descriptor.id, declared: .canonicalEvidence)
        }
        return .canonicalEvidence(MeetingCanonicalResultBundle(
            evidence: MeetingFinalTranscriptEvidence(
                backendID: self.descriptor.id,
                attemptID: bundle.evidence.attemptID,
                units: bundle.evidence.units,
                speakerActivity: bundle.evidence.speakerActivity,
                voiceProfiles: bundle.evidence.voiceProfiles,
                speakerSlotsContinueAcrossEpochs: bundle.evidence.speakerSlotsContinueAcrossEpochs
            ),
            coverageReceipts: bundle.coverageReceipts
        ))
    }
}

/// The first upload failure of an attempt. Upstream's backend swallows a failed epoch, so the
/// session leaves the error here for `GrokMeetingNemotronBackend.execute` to rethrow.
final nonisolated class GrokMeetingUploadFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: GrokSTTError?

    var first: GrokSTTError? {
        self.lock.withLock { self.failure }
    }

    func record(_ error: GrokSTTError) {
        self.lock.withLock { if self.failure == nil { self.failure = error } }
    }

    func reset() {
        self.lock.withLock { self.failure = nil }
    }
}

/// The local runtime with its speech phase replaced. Diarization and voice matching pass through.
final nonisolated class GrokMeetingRuntime: MeetingParakeetNemotronRunning {
    private let local: any MeetingParakeetNemotronRunning
    private let transcriber: GrokMeetingASRSession.Transcriber
    private let keyterms: @Sendable () async -> [String]
    private let failures: GrokMeetingUploadFailures
    private let maxRequestSamples: Int?

    init(
        local: any MeetingParakeetNemotronRunning,
        transcriber: @escaping GrokMeetingASRSession.Transcriber,
        keyterms: @escaping @Sendable () async -> [String],
        failures: GrokMeetingUploadFailures,
        maxRequestSamples: Int? = nil
    ) {
        self.local = local
        self.transcriber = transcriber
        self.keyterms = keyterms
        self.failures = failures
        self.maxRequestSamples = maxRequestSamples
    }

    func speakerVoiceProfiles(samples: [MeetingSpeakerVoiceSamples]) async throws -> [MeetingSpeakerVoiceProfile] {
        try await self.local.speakerVoiceProfiles(samples: samples)
    }

    func withNemotronDiarization(
        artifact: MeetingNemotronModelArtifact,
        _ body: @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult
    ) async throws -> MeetingNemotronPhaseResult {
        try await self.local.withNemotronDiarization(artifact: artifact, body)
    }

    /// No local speech model is prepared or held: the session only uploads.
    func withPreparedASR(
        attemptID _: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        body: @escaping @Sendable (any MeetingParakeetASRSession) async throws -> MeetingParakeetPhaseResult
    ) async throws -> MeetingParakeetPhaseResult {
        var session = GrokMeetingASRSession(
            languageCode: GrokSTTLanguage.normalized(configuration.languageCode),
            keyterms: await self.keyterms(),
            transcriber: self.transcriber,
            failures: self.failures
        )
        if let maxRequestSamples = self.maxRequestSamples { session.maxRequestSamples = maxRequestSamples }
        let prepared = session
        return try await body(prepared)
    }
}

/// Transcribes one epoch of meeting audio through xAI's REST endpoint and returns its word timings
/// in the epoch's own time, which is what upstream's backend expects from its speech session.
nonisolated struct GrokMeetingASRSession: MeetingParakeetASRSession {
    typealias Transcriber = @Sendable (_ samples: [Float], _ languageCode: String?, _ keyterms: [String]) async throws -> GrokSTTRESTTranscript

    /// One request holds at most this much audio, as the file path does.
    static let maxRequestSeconds = 20 * 60
    /// A request that failed for now is tried this many times in all.
    static let attempts = 3

    let languageCode: String?
    let keyterms: [String]
    let transcriber: Transcriber
    let failures: GrokMeetingUploadFailures
    var maxRequestSamples = GrokMeetingASRSession.maxRequestSeconds * GrokSTTAudioConverter.sampleRate
    /// Waits before the next try of a request; the argument is the try that just failed.
    var retryDelay: @Sendable (Int) async throws -> Void = { attempt in
        try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
    }

    static func restTranscriber(_ client: GrokSTTRESTClient = GrokSTTRESTClient(resolver: GrokSTTCredentialResolver.shared)) -> Transcriber {
        { samples, languageCode, keyterms in
            let duration = Double(samples.count) / Double(GrokSTTAudioConverter.sampleRate)
            return try await client.transcribePCMWithWords(
                samples,
                languageCode: languageCode,
                keyterms: keyterms,
                timeout: GrokSTTRESTClient.meetingTimeout(durationSeconds: duration)
            )
        }
    }

    func transcribeWithTimings(
        _ samples: [Float]
    ) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        let sampleRate = GrokSTTAudioConverter.sampleRate
        let chunk = max(sampleRate, self.maxRequestSamples)
        var texts: [String] = []
        var words: [ASRWordTiming] = []
        var hasUntimedText = false
        var offset = 0
        while offset < samples.count {
            try Task.checkCancellation()
            let end = min(samples.count, offset + chunk)
            let part = try await self.transcribe(Array(samples[offset..<end]))
            let shift = Double(offset) / Double(sampleRate)
            let limit = Double(end) / Double(sampleRate)
            if !part.text.isEmpty { texts.append(part.text) }
            if !part.text.isEmpty, part.words.isEmpty { hasUntimedText = true }
            for word in part.words {
                // Keep each word inside the audio it came from, and in order.
                let start = min(max(shift + word.start, shift), limit)
                let finish = min(max(shift + word.end, start), limit)
                words.append(ASRWordTiming(text: word.text, start: start, end: finish))
            }
            offset = end
        }
        // Upstream builds its units from the words alone whenever there are any. If one request
        // came back as text without timings, its text would vanish, so give up the timings of the
        // whole epoch instead: upstream then keeps all of the text as one utterance over the epoch.
        if hasUntimedText {
            GrokSTTLog.info("meeting_asr untimed text; using one utterance for this stretch")
            words = []
        }
        return (await ASRTranscriptionResult(text: texts.joined(separator: " ")), words)
    }

    /// Silence comes back as an empty transcript, not an error.
    private func transcribe(_ samples: [Float]) async throws -> GrokSTTRESTTranscript {
        // The attempt is already lost; do not upload the rest of the meeting for nothing.
        if let failure = self.failures.first { throw failure }
        var attempt = 1
        while true {
            do {
                return try await self.transcriber(samples, self.languageCode, self.keyterms)
            } catch is CancellationError {
                throw CancellationError()
            } catch GrokSTTError.emptyTranscript {
                return GrokSTTRESTTranscript(text: "", words: [])
            } catch {
                let failure = error as? GrokSTTError ?? GrokSTTTransportErrorMapper.map(error)
                guard failure.isRetryable, attempt < Self.attempts else {
                    self.failures.record(failure)
                    throw failure
                }
                try await self.retryDelay(attempt)
                attempt += 1
            }
        }
    }
}
