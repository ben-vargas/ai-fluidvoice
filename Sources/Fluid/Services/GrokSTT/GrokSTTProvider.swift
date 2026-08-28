import Foundation

/// Cloud Grok Speech provider. WebSocket dictation + REST empty-socket retry.
/// Not MainActor — `TranscriptionExecutor.run { transcribeFinal }` would deadlock if it were.
final nonisolated class GrokSTTProvider: TranscriptionProvider, StreamingTranscriptionProviding, @unchecked Sendable {
    let name = "Grok Speech (xAI)"
    let isAvailable = true
    let prefersNativeFileTranscription = true
    let shouldClearCacheAfterCancellation = false

    private let resolver: any GrokSTTCredentialResolving
    private let restClient: GrokSTTRESTClient
    private let socketTransport: any GrokSTTWebSocketTransporting
    private let cliSocketEnabled: Bool
    private let apiKeySocketEnabled: Bool
    private let lock = NSLock()
    /// Meetings / LocalAPI PCM REST stays closed until PR4's consent notices land.
    private static let restNotYetAvailable = GrokSTTError.server(
        status: 501,
        message: "Grok REST speech-to-text is not available yet."
    )

    #if DEBUG
    private var sessionFactory: ((StreamingSTTSessionConfiguration) throws -> StreamingTranscriptionSession)?
    private var restFinalHandler: (@Sendable ([Float], String?) async throws -> ASRTranscriptionResult)?
    private var restFileHandler: (@Sendable (URL) async throws -> ASRTranscriptionResult)?
    private var prepareHandler: (@Sendable (((ModelPreparationProgress) -> Void)?) async throws -> Void)?
    private var prepareCallCountStorage = 0
    #endif

    init(
        resolver: any GrokSTTCredentialResolving = GrokSTTCredentialResolver.shared,
        restClient: GrokSTTRESTClient? = nil,
        socketTransport: (any GrokSTTWebSocketTransporting)? = nil,
        cliSocketEnabled: Bool = SettingsStore.SpeechModel.grokSTTCLISocketEnabled,
        apiKeySocketEnabled: Bool = SettingsStore.SpeechModel.grokSTTAPIKeySocketEnabled
    ) {
        self.resolver = resolver
        self.restClient = restClient ?? GrokSTTRESTClient(resolver: resolver)
        self.socketTransport = socketTransport ?? GrokSTTURLSessionWebSocketTransport()
        self.cliSocketEnabled = cliSocketEnabled
        self.apiKeySocketEnabled = apiKeySocketEnabled
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
        // Credential I/O (Keychain, CLI store) must not inherit the caller's
        // executor: ensureAsrReady invokes prepare from a MainActor task.
        let resolver = self.resolver
        _ = try await Task.detached {
            try await resolver.resolveCredential()
        }.value
    }

    nonisolated func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        _ = samples
        throw Self.restNotYetAvailable
    }

    nonisolated func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        _ = samples
        throw GrokSTTError.server(status: 500, message: "Grok Speech does not use the local streaming pull loop.")
    }

    nonisolated func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        _ = samples
        throw Self.restNotYetAvailable
    }

    nonisolated func transcribeFinal(
        _ samples: [Float],
        languageCode: String?,
        keyterms: [String]?
    ) async throws -> ASRTranscriptionResult {
        try await Task.detached { [samples, languageCode, keyterms] in
            #if DEBUG
            if let restFinalHandler = self.lock.withLock({ self.restFinalHandler }) {
                return try await restFinalHandler(samples, languageCode)
            }
            #endif
            return try await self.restClient.transcribePCM(
                samples,
                languageCode: Self.wireLanguageCode(languageCode),
                keyterms: keyterms ?? []
            )
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
            throw Self.restNotYetAvailable
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
        var sessionConfiguration = configuration
        sessionConfiguration.languageCode = Self.wireLanguageCode(configuration.languageCode)
        return GrokSTTWebSocketSession(
            configuration: sessionConfiguration,
            resolver: self.resolver,
            transport: self.socketTransport,
            cliSocketEnabled: self.cliSocketEnabled,
            apiKeySocketEnabled: self.apiKeySocketEnabled
        )
    }

    /// Wire `language` value. `nil` / Auto omits the param. Catalog `tl` is sent as `fil`.
    nonisolated static func wireLanguageCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("auto") == .orderedSame {
            return nil
        }
        return trimmed == "tl" ? "fil" : trimmed
    }
}
