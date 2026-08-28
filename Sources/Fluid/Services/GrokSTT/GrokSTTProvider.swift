import Foundation

/// Cloud Grok Speech provider. Session factory is real in PR3b; REST throws until then.
/// Not MainActor — `TranscriptionExecutor.run { transcribeFinal }` would deadlock if it were.
final nonisolated class GrokSTTProvider: TranscriptionProvider, StreamingTranscriptionProviding, @unchecked Sendable {
    let name = "Grok Speech (xAI)"
    let isAvailable = true
    let prefersNativeFileTranscription = true
    let shouldClearCacheAfterCancellation = false

    private let resolver: any GrokSTTCredentialResolving
    private let lock = NSLock()

    #if DEBUG
    private var sessionFactory: ((StreamingSTTSessionConfiguration) throws -> StreamingTranscriptionSession)?
    private var restFinalHandler: (@Sendable ([Float], String?) async throws -> ASRTranscriptionResult)?
    private var restFileHandler: (@Sendable (URL) async throws -> ASRTranscriptionResult)?
    private var prepareHandler: (@Sendable (((ModelPreparationProgress) -> Void)?) async throws -> Void)?
    private var prepareCallCountStorage = 0
    #endif

    init(resolver: any GrokSTTCredentialResolving = GrokSTTCredentialResolver.shared) {
        self.resolver = resolver
    }

    var isReady: Bool {
        self.resolver.isSourceConfigured
    }

    #if DEBUG
    var prepareCallCount: Int {
        self.lock.withLock { self.prepareCallCountStorage }
    }

    func setSessionFactory(_ factory: ((StreamingSTTSessionConfiguration) throws -> StreamingTranscriptionSession)?) {
        self.lock.withLock { self.sessionFactory = factory }
    }

    func setRestFinalHandler(_ handler: (@Sendable ([Float], String?) async throws -> ASRTranscriptionResult)?) {
        self.lock.withLock { self.restFinalHandler = handler }
    }

    func setRestFileHandler(_ handler: (@Sendable (URL) async throws -> ASRTranscriptionResult)?) {
        self.lock.withLock { self.restFileHandler = handler }
    }

    func setPrepareHandler(_ handler: (@Sendable (((ModelPreparationProgress) -> Void)?) async throws -> Void)?) {
        self.lock.withLock { self.prepareHandler = handler }
    }
    #endif

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        #if DEBUG
        self.lock.withLock { self.prepareCallCountStorage += 1 }
        #endif
        progressHandler?(.loading)
        #if DEBUG
        if let prepareHandler = self.lock.withLock({ self.prepareHandler }) {
            try await prepareHandler(progressHandler)
            return
        }
        #endif
        _ = try await self.resolver.resolveCredential()
    }

    nonisolated func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    nonisolated func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        _ = samples
        throw GrokSTTError.server(status: 500, message: "Grok Speech does not use the local streaming pull loop.")
    }

    nonisolated func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples, languageCode: nil)
    }

    nonisolated func transcribeFinal(_ samples: [Float], languageCode: String?) async throws -> ASRTranscriptionResult {
        try await Task.detached { [samples, languageCode] in
            #if DEBUG
            if let restFinalHandler = self.lock.withLock({ self.restFinalHandler }) {
                return try await restFinalHandler(samples, languageCode)
            }
            #endif
            throw GrokSTTError.server(status: 501, message: "Grok REST speech-to-text is not available yet.")
        }.value
    }

    nonisolated func transcribeDictionaryTraining(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        _ = samples
        throw GrokSTTError.dictionaryTrainingUnsupported
    }

    nonisolated func transcribeFile(at fileURL: URL) async throws -> ASRTranscriptionResult {
        try await Task.detached {
            #if DEBUG
            if let restFileHandler = self.lock.withLock({ self.restFileHandler }) {
                return try await restFileHandler(fileURL)
            }
            #endif
            throw GrokSTTError.server(status: 501, message: "Grok REST speech-to-text is not available yet.")
        }.value
    }

    func modelsExistOnDisk() -> Bool { false }

    func clearCache() async throws {}

    func makeStreamingSession(
        configuration: StreamingSTTSessionConfiguration
    ) throws -> StreamingTranscriptionSession {
        #if DEBUG
        if let factory = self.lock.withLock({ self.sessionFactory }) {
            return try factory(configuration)
        }
        #endif
        throw GrokSTTError.server(status: 501, message: "Grok streaming speech-to-text is not available yet.")
    }
}
