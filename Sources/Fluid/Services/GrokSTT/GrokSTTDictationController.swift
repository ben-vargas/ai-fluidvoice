import Foundation

/// Owns the xAI socket for one push-to-talk recording.
///
/// ASRService already polls the selected provider with the whole recording so far
/// (`transcribeStreaming`) and hands it the whole recording again at stop
/// (`transcribeFinal`). This controller turns that pull loop into a push stream:
/// each poll sends only the samples the socket has not seen and returns the
/// socket's assembled transcript, so no ASRService audio plumbing is Grok-specific.
actor GrokSTTDictationController {
    struct Configuration: Sendable, Equatable {
        var languageCode: String?
        var keyterms: [String]
    }

    typealias SessionFactory = @Sendable (StreamingSTTSessionConfiguration) -> any StreamingTranscriptionSession
    typealias RESTTranscriber = @Sendable ([Float], Configuration) async throws -> String

    static let sendQueuePauseLimit = 20
    /// Closes a socket whose recording ended without reaching `finish` (for example a
    /// stop that found no audio), so it does not stay open until the next dictation.
    static let idleTimeout: TimeInterval = 15

    private let makeSession: SessionFactory
    private let transcribeREST: RESTTranscriber

    private var generation: UInt64?
    private var configuration = Configuration(languageCode: nil, keyterms: [])
    private var session: (any StreamingTranscriptionSession)?
    private var sessionID = UUID()
    private var created = false
    private var sentSamples = 0
    private var lastActivity = Date()
    private var isFinishing = false
    private var idleWatch: Task<Void, Never>?

    init(makeSession: @escaping SessionFactory, transcribeREST: @escaping RESTTranscriber) {
        self.makeSession = makeSession
        self.transcribeREST = transcribeREST
    }

    /// Sends newly captured audio and returns the live transcript for this recording.
    func preview(_ samples: [Float], generation: UInt64, configuration: Configuration) -> String {
        self.adopt(generation: generation, configuration: configuration)
        self.lastActivity = Date()
        guard let session = self.openSessionIfNeeded() else { return "" }
        if self.created, session.transportError == nil {
            self.send(samples, includePartialFrame: false, respectQueueLimit: true)
        }
        return session.transcript
    }

    /// Sends the rest of the recording, waits for the socket's final text, and falls
    /// back to one REST upload of the whole recording when the socket produced nothing.
    func finish(_ samples: [Float], generation: UInt64, configuration: Configuration) async throws -> String {
        self.adopt(generation: generation, configuration: configuration)
        self.isFinishing = true
        defer { self.isFinishing = false }
        let session = self.openSessionIfNeeded()
        let finishingSessionID = self.sessionID

        if let session {
            if self.created, self.sentSamples > 0 {
                self.send(samples, includePartialFrame: true, respectQueueLimit: false)
            } else {
                // Nothing was appended yet (slow handshake or a very short hold):
                // the session sends the whole recording once `transcript.created` arrives.
                session.handoffUnsentPCM(samples)
            }
            do {
                let text = try await session.finish()
                try self.checkCurrent(generation: generation, sessionID: finishingSessionID)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.close(generation: generation)
                    return text
                }
                GrokSTTLog.info("socket_empty falling_back=rest")
            } catch {
                try self.checkCurrent(generation: generation, sessionID: finishingSessionID)
                GrokSTTLog.info("socket_failed error=\(String(describing: error)) falling_back=rest")
            }
        }

        self.close(generation: generation)
        return try await self.transcribeREST(samples, configuration)
    }

    func cancel(generation: UInt64) {
        guard self.generation == generation else { return }
        self.close(generation: generation)
    }

    // MARK: - Private

    private func adopt(generation: UInt64, configuration: Configuration) {
        guard self.generation != generation else { return }
        self.tearDownSession()
        self.generation = generation
        self.configuration = configuration
    }

    private func openSessionIfNeeded() -> (any StreamingTranscriptionSession)? {
        if let session = self.session { return session }
        guard self.generation != nil else { return nil }

        var sessionConfiguration = StreamingSTTSessionConfiguration.grokDictation
        sessionConfiguration.languageCode = self.configuration.languageCode
        sessionConfiguration.keyterms = self.configuration.keyterms
        let session = self.makeSession(sessionConfiguration)
        let sessionID = UUID()
        self.session = session
        self.sessionID = sessionID
        self.created = false
        self.sentSamples = 0

        self.startIdleWatchIfNeeded()
        Task.detached { [weak self] in
            do {
                try await session.start()
                await self?.markCreated(sessionID: sessionID)
            } catch {
                GrokSTTLog.info("session_start_failed error=\(String(describing: error))")
            }
        }
        return session
    }

    private func startIdleWatchIfNeeded() {
        guard self.idleWatch == nil else { return }
        self.idleWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                if await self.closeIfIdle() { return }
            }
        }
    }

    /// Returns true when the watch should stop (no session left to guard).
    private func closeIfIdle() -> Bool {
        guard self.session != nil, let generation = self.generation else {
            self.idleWatch = nil
            return true
        }
        guard !self.isFinishing, Date().timeIntervalSince(self.lastActivity) > Self.idleTimeout else {
            return false
        }
        GrokSTTLog.info("session_idle_closed")
        self.close(generation: generation)
        self.idleWatch = nil
        return true
    }

    private func markCreated(sessionID: UUID) {
        guard self.sessionID == sessionID, self.session != nil else { return }
        self.created = true
    }

    private func send(_ samples: [Float], includePartialFrame: Bool, respectQueueLimit: Bool) {
        guard let session = self.session else { return }
        let frameSize = GrokSTTAudioConverter.samplesPerFrame
        while samples.count - self.sentSamples >= frameSize {
            if respectQueueLimit, session.queuedAudioFrameCount > Self.sendQueuePauseLimit { return }
            let end = self.sentSamples + frameSize
            session.append(pcm16: GrokSTTAudioConverter.pcm16LE(fromFloat32: samples[self.sentSamples..<end]))
            self.sentSamples = end
        }
        if includePartialFrame, samples.count > self.sentSamples {
            session.append(pcm16: GrokSTTAudioConverter.pcm16LE(fromFloat32: samples[self.sentSamples...]))
            self.sentSamples = samples.count
        }
    }

    private func checkCurrent(generation: UInt64, sessionID: UUID) throws {
        guard self.generation == generation, self.sessionID == sessionID else {
            throw CancellationError()
        }
    }

    private func close(generation: UInt64) {
        guard self.generation == generation else { return }
        self.tearDownSession()
        self.generation = nil
    }

    private func tearDownSession() {
        self.session?.cancel()
        self.session = nil
        self.sessionID = UUID()
        self.created = false
        self.sentSamples = 0
    }
}
