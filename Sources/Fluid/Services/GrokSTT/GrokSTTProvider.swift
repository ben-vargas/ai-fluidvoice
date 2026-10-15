import Foundation

/// Cloud speech-to-text through xAI. Dictation streams over the `/v1/stt` WebSocket;
/// files, meetings, the local API and the empty-socket fallback use the REST endpoint.
final class GrokSTTProvider: LiveSessionTranscriptionProvider {
    let name = "Grok Speech (xAI)"
    let isAvailable = true
    let prefersNativeFileTranscription = true
    let shouldClearCacheAfterCancellation = false

    private let resolver: any GrokSTTCredentialResolving
    private let restClient: GrokSTTRESTClient
    private let dictation: GrokSTTDictationController
    private var hasPrepared = false
    private var liveGeneration: UInt64 = 0
    private var liveRecording: (generation: UInt64, configuration: GrokSTTDictationController.Configuration)?

    init(
        resolver: any GrokSTTCredentialResolving = GrokSTTCredentialResolver.shared,
        transport: any GrokSTTWebSocketTransporting = GrokSTTURLSessionWebSocketTransport()
    ) {
        let restClient = GrokSTTRESTClient(resolver: resolver)
        self.resolver = resolver
        self.restClient = restClient
        self.dictation = GrokSTTDictationController(
            makeSession: { configuration in
                GrokSTTWebSocketSession(configuration: configuration, resolver: resolver, transport: transport)
            },
            transcribeREST: { samples, configuration in
                try await restClient.transcribePCM(
                    samples,
                    languageCode: configuration.languageCode,
                    keyterms: configuration.keyterms
                )
            }
        )
    }

    /// No disk or Keychain reads here: ASRService checks this on every preview tick.
    /// A credential that disappears later surfaces as a request error instead.
    var isReady: Bool {
        self.hasPrepared
    }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        progressHandler?(.loading)
        // Only checks that the selected sign-in exists. ASRService awaits this after capture
        // has stopped, so a network refresh here could lose the recording on failure. Resolving
        // (and refreshing an expired Grok CLI session) happens per request instead, where a
        // failure keeps the audio for Retry.
        guard self.resolver.isSourceConfigured else {
            throw GrokSTTError.noCredentialConfigured
        }
        self.hasPrepared = true
    }

    func modelsExistOnDisk() -> Bool { true }

    // MARK: - Dictation

    func recordingSessionWillStart() {
        self.liveGeneration &+= 1
        self.liveRecording = (self.liveGeneration, Self.currentConfiguration())
        GrokSTTRetryCenter.shared.clear()
    }

    func recordingSessionDidCancel() {
        guard let live = self.liveRecording else { return }
        self.liveRecording = nil
        let dictation = self.dictation
        Task { await dictation.cancel(generation: live.generation) }
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard let live = self.liveRecording else { return ASRTranscriptionResult(text: "") }
        let text = await self.dictation.preview(samples, generation: live.generation, configuration: live.configuration)
        return ASRTranscriptionResult(text: text)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard let live = self.liveRecording else {
            // Not a dictation recording (for example the local API): one REST upload.
            return try await self.transcribeWithREST(samples)
        }
        self.liveRecording = nil
        do {
            let text = try await self.dictation.finish(samples, generation: live.generation, configuration: live.configuration)
            return ASRTranscriptionResult(text: text)
        } catch is CancellationError {
            throw CancellationError()
        } catch GrokSTTError.emptyTranscript, GrokSTTError.invalidAudio {
            // Nothing intelligible was said; behave like a local engine's empty result.
            return ASRTranscriptionResult(text: "", confidence: 0)
        } catch {
            let failure = error as? GrokSTTError ?? GrokSTTTransportErrorMapper.map(error)
            GrokSTTLog.error("dictation_failed error=\(String(describing: failure))")
            GrokSTTRetryCenter.shared.retain(samples: samples, error: failure, configuration: live.configuration)
            throw failure
        }
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeWithREST(samples)
    }

    func transcribeDictionaryTraining(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        throw GrokSTTError.dictionaryTrainingUnsupported
    }

    func transcribeDictionaryTraining(_ samples: [Float], capturePronunciation: Bool) async throws -> ASRTranscriptionResult {
        throw GrokSTTError.dictionaryTrainingUnsupported
    }

    func transcribeFile(at fileURL: URL) async throws -> ASRTranscriptionResult {
        let configuration = Self.currentConfiguration()
        guard GrokSTTRESTClient.acceptsNativeUpload(fileURL) else {
            return try await self.transcribeDecodedFile(at: fileURL, configuration: configuration)
        }
        do {
            let text = try await self.restClient.transcribeFile(
                at: fileURL,
                languageCode: configuration.languageCode,
                keyterms: configuration.keyterms
            )
            return ASRTranscriptionResult(text: text)
        } catch GrokSTTError.emptyTranscript {
            return ASRTranscriptionResult(text: "", confidence: 0)
        }
    }

    /// xAI rejects some containers FluidVoice reads, including the CAF chunks meetings
    /// record. Decode those to 16 kHz mono and upload WAV, at most 20 minutes per request.
    private func transcribeDecodedFile(
        at fileURL: URL,
        configuration: GrokSTTDictationController.Configuration
    ) async throws -> ASRTranscriptionResult {
        let reader: LocalAPIAudioDecoder.ChunkReader
        do {
            reader = try LocalAPIAudioDecoder.ChunkReader(fileURL: fileURL)
        } catch {
            throw GrokSTTError.unsupportedFile
        }
        var parts: [String] = []
        while true {
            let samples = try await reader.nextSamples()
            guard !samples.isEmpty else { break }
            let duration = Double(samples.count) / Double(GrokSTTAudioConverter.sampleRate)
            do {
                let text = try await self.restClient.transcribePCM(
                    samples,
                    languageCode: configuration.languageCode,
                    keyterms: configuration.keyterms,
                    timeout: GrokSTTRESTClient.meetingTimeout(durationSeconds: duration)
                )
                parts.append(text)
            } catch GrokSTTError.emptyTranscript {
                continue
            }
        }
        return ASRTranscriptionResult(text: parts.joined(separator: " "), confidence: parts.isEmpty ? 0 : 1)
    }

    // MARK: - REST

    /// Uploads PCM in one request. Silence comes back as empty text, not an error,
    /// so meeting chunks without speech do not fail the whole meeting.
    private func transcribeWithREST(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        let configuration = Self.currentConfiguration()
        let duration = Double(samples.count) / Double(GrokSTTAudioConverter.sampleRate)
        do {
            let text = try await self.restClient.transcribePCM(
                samples,
                languageCode: configuration.languageCode,
                keyterms: configuration.keyterms,
                timeout: GrokSTTRESTClient.meetingTimeout(durationSeconds: duration)
            )
            return ASRTranscriptionResult(text: text)
        } catch GrokSTTError.emptyTranscript {
            return ASRTranscriptionResult(text: "", confidence: 0)
        }
    }

    static func currentConfiguration() -> GrokSTTDictationController.Configuration {
        GrokSTTDictationController.Configuration(
            languageCode: GrokSTTLanguage.wireCode(SettingsStore.shared.selectedGrokSTTLanguageCode),
            keyterms: GrokSTTKeytermBuilder.terms()
        )
    }
}
