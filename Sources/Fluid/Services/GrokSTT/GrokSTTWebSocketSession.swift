import Foundation

/// One dictation = one xAI WebSocket session. Off MainActor. Audio send is gated on `transcript.created`.
final nonisolated class GrokSTTWebSocketSession: NSObject, StreamingTranscriptionSession, @unchecked Sendable {
    static let endpoint = URL(string: "wss://api.x.ai/v1/stt")!
    static let createdBudget: TimeInterval = 20
    static let doneTimeout: TimeInterval = 3

    enum State: String, Sendable {
        case idle
        case connecting
        case waitCreated
        case streaming
        case finishing
        case complete
        case cancelled
        case failed
    }

    private let configuration: StreamingSTTSessionConfiguration
    private let resolver: any GrokSTTCredentialResolving
    private let transport: any GrokSTTWebSocketTransporting
    private let cliSocketEnabled: Bool
    private let lock = NSLock()

    private var assembler = GrokSTTTranscriptAssembler()
    private var state: State = .idle
    private var stickyError: GrokSTTError?
    private var handoffSamples: [Float] = []
    private var pendingFrames: [Data] = []
    private var onPartialHandler: (@MainActor (String) -> Void)?
    private var connection: (any GrokSTTWebSocketConnection)?
    private var receiveTask: Task<Void, Never>?
    private var connectStartedAt: Date?
    private var audioDoneSent = false
    private var appendedFrameCount = 0
    private var credential: GrokSTTCredential?
    private var didRetryUnauthorized = false
    private var createdWaiters: [CheckedContinuation<Void, Error>] = []
    private var finishWaiters: [CheckedContinuation<String, Error>] = []
    private var sending = false

    init(
        configuration: StreamingSTTSessionConfiguration,
        resolver: any GrokSTTCredentialResolving,
        transport: any GrokSTTWebSocketTransporting = GrokSTTURLSessionWebSocketTransport(),
        cliSocketEnabled: Bool = SettingsStore.SpeechModel.grokSTTCLISocketEnabled
    ) {
        self.configuration = configuration
        self.resolver = resolver
        self.transport = transport
        self.cliSocketEnabled = cliSocketEnabled
        super.init()
    }

    var transcript: String {
        self.lock.withLock { self.assembler.transcript }
    }

    var transportError: GrokSTTError? {
        self.lock.withLock { self.stickyError }
    }

    var onPartial: (@MainActor (String) -> Void)? {
        get { self.lock.withLock { self.onPartialHandler } }
        set { self.lock.withLock { self.onPartialHandler = newValue } }
    }

    var queuedAudioFrameCount: Int {
        self.lock.withLock { self.pendingFrames.count }
    }

    var currentState: State {
        self.lock.withLock { self.state }
    }

    var debugAudioDoneSent: Bool {
        self.lock.withLock { self.audioDoneSent }
    }

    var debugAppendedFrameCount: Int {
        self.lock.withLock { self.appendedFrameCount }
    }

    @concurrent func start() async throws {
        #if DEBUG
        assert(!Thread.isMainThread, "GrokSTTWebSocketSession.start() must run off the main thread")
        #endif

        let alreadyStarted: Bool = self.lock.withLock {
            if self.state == .idle {
                self.state = .connecting
                self.connectStartedAt = Date()
                return false
            }
            return true
        }
        if alreadyStarted {
            try await self.waitUntilCreated()
            return
        }

        do {
            try await self.connectAndWaitCreated()
        } catch {
            self.fail(self.mapError(error), close: true)
            throw self.lock.withLock({ self.stickyError }) ?? self.mapError(error)
        }
    }

    func append(pcm16: Data) {
        self.lock.lock()
        if self.state != .streaming {
            self.lock.unlock()
            return
        }
        self.pendingFrames.append(pcm16)
        self.appendedFrameCount += 1
        let shouldKick = !self.sending
        if shouldKick {
            self.sending = true
        }
        self.lock.unlock()
        if shouldKick {
            Task.detached { [weak self] in
                await self?.drainPendingFrames()
            }
        }
    }

    func handoffUnsentPCM(_ samples: [Float]) {
        self.lock.withLock {
            if self.state == .streaming, self.appendedFrameCount > 0 {
                return
            }
            guard self.state == .waitCreated
                || self.state == .idle
                || self.state == .connecting
                || self.state == .streaming
            else {
                return
            }
            self.handoffSamples = samples
        }
    }

    @concurrent func finish() async throws -> String {
        #if DEBUG
        assert(!Thread.isMainThread, "GrokSTTWebSocketSession.finish() must run off the main thread")
        #endif

        let snapshot = self.lock.withLock { () -> (State, GrokSTTError?, Bool) in
            (self.state, self.stickyError, self.audioDoneSent)
        }
        if snapshot.0 == .cancelled {
            throw GrokSTTError.cancelled
        }
        if let error = snapshot.1, !snapshot.2 {
            throw error
        }
        if snapshot.0 == .complete {
            let text = self.transcript
            if text.isEmpty {
                throw GrokSTTError.emptyTranscript
            }
            return text
        }

        do {
            try await self.waitUntilCreated()
        } catch {
            throw self.mapError(error)
        }

        let preDoneError = self.lock.withLock { self.audioDoneSent ? nil : self.stickyError }
        if let preDoneError {
            throw preDoneError
        }

        try await self.flushHandoffIfNeeded()
        try await self.sendAudioDone()
        return try await self.waitForDone()
    }

    func cancel() {
        self.lock.lock()
        let alreadyTerminal = self.state == .cancelled || self.state == .complete
        self.state = .cancelled
        self.pendingFrames.removeAll()
        self.sending = false
        let created = self.createdWaiters
        self.createdWaiters = []
        let finishers = self.finishWaiters
        self.finishWaiters = []
        let connection = self.connection
        self.connection = nil
        let receiveTask = self.receiveTask
        self.receiveTask = nil
        self.lock.unlock()

        created.forEach { $0.resume(throwing: GrokSTTError.cancelled) }
        finishers.forEach { $0.resume(throwing: GrokSTTError.cancelled) }
        receiveTask?.cancel()
        if !alreadyTerminal {
            connection?.close()
        }
    }

    static func makeURL(configuration: StreamingSTTSessionConfiguration) -> URL {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false) ?? URLComponents()
        var items: [URLQueryItem] = [
            URLQueryItem(name: "sample_rate", value: "\(configuration.sampleRate)"),
            URLQueryItem(name: "encoding", value: "pcm"),
            URLQueryItem(name: "interim_results", value: configuration.interimResults ? "true" : "false"),
        ]
        if let language = configuration.languageCode, !language.isEmpty {
            items.append(URLQueryItem(name: "language", value: language))
        }
        for term in configuration.keyterms {
            items.append(URLQueryItem(name: "keyterm", value: term))
        }
        components.queryItems = items
        return components.url ?? Self.endpoint
    }

    // MARK: - Connect

    private func connectAndWaitCreated() async throws {
        var credential = try await self.resolver.resolveCredential()
        if credential.source == .grokCLISession, !self.cliSocketEnabled {
            throw GrokSTTError.server(
                status: 501,
                message: "CLI WebSocket is disabled. Use an API key for dictation."
            )
        }
        self.lock.withLock { self.credential = credential }

        while true {
            try Task.checkCancellation()
            let request = Self.makeRequest(configuration: self.configuration, credential: credential)
            do {
                let connection = try await self.transport.connect(request: request)
                self.lock.withLock {
                    self.connection = connection
                    if self.state == .connecting {
                        self.state = .waitCreated
                    }
                }
                self.startReceiveLoop(connection)
                try await self.waitUntilCreated()
                return
            } catch {
                let mapped = self.mapError(error)
                if mapped == .unauthorized,
                   credential.source == .grokCLISession,
                   !self.lock.withLock({ self.didRetryUnauthorized })
                {
                    self.lock.withLock { self.didRetryUnauthorized = true }
                    credential = try await self.resolver.resolveCredentialAfterUnauthorized(
                        rejectedBearerFingerprint: credential.bearerFingerprint
                    )
                    self.lock.withLock { self.credential = credential }
                    self.closeConnection()
                    continue
                }
                throw mapped
            }
        }
    }

    static func makeRequest(
        configuration: StreamingSTTSessionConfiguration,
        credential: GrokSTTCredential
    ) -> URLRequest {
        var request = URLRequest(url: Self.makeURL(configuration: configuration))
        request.setValue("Bearer \(credential.bearer)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = GrokSTTURLSessionWebSocketTransport.connectTimeout
        return request
    }

    private func startReceiveLoop(_ connection: any GrokSTTWebSocketConnection) {
        let task = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await connection.receive()
                    self.handle(message)
                } catch {
                    if Task.isCancelled { return }
                    self.handleTransportFailure(error)
                    return
                }
            }
        }
        self.lock.withLock {
            self.receiveTask?.cancel()
            self.receiveTask = task
        }
    }

    private func handle(_ message: GrokSTTWebSocketMessage) {
        switch message {
        case let .text(text):
            self.handleJSONText(text)
        case .data:
            break
        }
    }

    private func handleJSONText(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let event = try? JSONDecoder().decode(GrokSTTServerEvent.self, from: data)
        else {
            return
        }
        switch event.type {
        case "transcript.created":
            self.markCreated()
        case "transcript.partial":
            self.recordPartial(start: event.start ?? 0, text: event.text ?? "")
        case "transcript.done":
            self.recordDone(text: event.text ?? "")
        case "error":
            self.fail(
                GrokSTTError.server(
                    status: 500,
                    message: GrokSTTSanitizedMessage(event.message ?? "server error")
                ),
                close: true
            )
        default:
            break
        }
    }

    private func markCreated() {
        var waiters: [CheckedContinuation<Void, Error>] = []
        self.lock.lock()
        if self.state == .waitCreated || self.state == .connecting || self.state == .idle {
            self.state = .streaming
        }
        waiters = self.createdWaiters
        self.createdWaiters = []
        self.lock.unlock()
        waiters.forEach { $0.resume() }
    }

    private func recordPartial(start: Double, text: String) {
        let snapshot: String = self.lock.withLock {
            self.assembler.record(start: start, text: text)
            return self.assembler.transcript
        }
        let handler = self.onPartial
        guard !snapshot.isEmpty, let handler else { return }
        Task { @MainActor in
            handler(snapshot)
        }
    }

    private func recordDone(text: String) {
        let assembled: String = self.lock.withLock {
            self.assembler.replaceWithServerText(text)
            if self.state != .cancelled {
                self.state = .complete
            }
            return self.assembler.transcript
        }
        self.resumeFinishWaiters(.success(assembled))
        self.closeConnection()
    }

    private func handleTransportFailure(_ error: Error) {
        let mapped = self.mapError(error)
        let audioDone = self.lock.withLock { self.audioDoneSent }
        if audioDone {
            let assembled = self.transcript
            if !assembled.isEmpty {
                self.lock.withLock {
                    if self.state != .cancelled {
                        self.state = .complete
                    }
                }
                self.resumeFinishWaiters(.success(assembled))
                return
            }
            self.fail(mapped, close: false)
            return
        }
        self.fail(mapped, close: false)
    }

    private func fail(_ error: GrokSTTError, close: Bool) {
        self.lock.lock()
        if self.stickyError == nil {
            self.stickyError = error
        }
        if self.state != .cancelled, self.state != .complete {
            self.state = .failed
        }
        let created = self.createdWaiters
        self.createdWaiters = []
        let finishers = self.finishWaiters
        self.finishWaiters = []
        self.pendingFrames.removeAll()
        self.sending = false
        self.lock.unlock()
        created.forEach { $0.resume(throwing: error) }
        finishers.forEach { $0.resume(throwing: error) }
        if close {
            self.closeConnection()
        }
    }

    private func waitUntilCreated() async throws {
        let remaining = self.remainingCreatedBudget()
        if remaining <= 0 {
            self.fail(.timeout, close: true)
            throw GrokSTTError.timeout
        }

        do {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try await self.awaitCreatedGate()
                    return true
                }
                group.addTask {
                    let nanoseconds = UInt64(remaining * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanoseconds)
                    return false
                }
                let created = try await group.next()!
                group.cancelAll()
                if !created {
                    self.fail(.timeout, close: true)
                    throw GrokSTTError.timeout
                }
            }
        } catch {
            throw self.mapError(error)
        }
    }

    private func awaitCreatedGate() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.lock.lock()
            if self.state == .streaming || self.state == .finishing || self.state == .complete {
                self.lock.unlock()
                continuation.resume()
                return
            }
            if self.state == .cancelled {
                self.lock.unlock()
                continuation.resume(throwing: GrokSTTError.cancelled)
                return
            }
            if let error = self.stickyError {
                self.lock.unlock()
                continuation.resume(throwing: error)
                return
            }
            self.createdWaiters.append(continuation)
            self.lock.unlock()
        }
    }

    private func remainingCreatedBudget() -> TimeInterval {
        let started = self.lock.withLock { self.connectStartedAt } ?? Date()
        return Self.createdBudget - Date().timeIntervalSince(started)
    }

    private func flushHandoffIfNeeded() async throws {
        let samples: [Float] = self.lock.withLock {
            let copy = self.handoffSamples
            self.handoffSamples = []
            return copy
        }
        guard !samples.isEmpty else {
            await self.drainPendingFrames()
            return
        }
        let frameSize = GrokSTTAudioConverter.samplesPerFrame
        var offset = 0
        while offset < samples.count {
            let end = min(offset + frameSize, samples.count)
            let frame = GrokSTTAudioConverter.pcm16LE(fromFloat32: samples[offset..<end])
            try await self.sendFrame(frame)
            offset = end
        }
        await self.drainPendingFrames()
    }

    private func sendAudioDone() async throws {
        let already: Bool = self.lock.withLock {
            if self.audioDoneSent {
                return true
            }
            self.audioDoneSent = true
            if self.state == .streaming || self.state == .waitCreated {
                self.state = .finishing
            }
            return false
        }
        if already { return }
        await self.drainPendingFrames()
        try await self.sendText(#"{"type":"audio.done"}"#)
    }

    private func waitForDone() async throws -> String {
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await self.awaitDoneGate()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(Self.doneTimeout * 1_000_000_000))
                    let assembled = self.transcript
                    if !assembled.isEmpty {
                        return assembled
                    }
                    throw GrokSTTError.timeout
                }
                let text = try await group.next()!
                group.cancelAll()
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    self.resumeFinishWaiters(.failure(GrokSTTError.timeout))
                    throw GrokSTTError.timeout
                }
                self.lock.withLock {
                    if self.state != .cancelled {
                        self.state = .complete
                    }
                }
                self.resumeFinishWaiters(.success(text))
                return text
            }
        } catch {
            let mapped = self.mapError(error)
            if mapped == .timeout {
                let assembled = self.transcript
                if !assembled.isEmpty {
                    return assembled
                }
            }
            self.resumeFinishWaiters(.failure(mapped))
            throw mapped
        }
    }

    private func awaitDoneGate() async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            self.lock.lock()
            if self.state == .complete {
                let text = self.assembler.transcript
                self.lock.unlock()
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continuation.resume(throwing: GrokSTTError.timeout)
                } else {
                    continuation.resume(returning: text)
                }
                return
            }
            if self.state == .cancelled {
                self.lock.unlock()
                continuation.resume(throwing: GrokSTTError.cancelled)
                return
            }
            if let error = self.stickyError, self.audioDoneSent == false {
                self.lock.unlock()
                continuation.resume(throwing: error)
                return
            }
            self.finishWaiters.append(continuation)
            self.lock.unlock()
        }
    }

    private func resumeFinishWaiters(_ result: Result<String, Error>) {
        self.lock.lock()
        let waiters = self.finishWaiters
        self.finishWaiters = []
        self.lock.unlock()
        waiters.forEach { $0.resume(with: result) }
    }

    private func drainPendingFrames() async {
        while true {
            let frame: Data? = self.lock.withLock {
                if self.pendingFrames.isEmpty {
                    self.sending = false
                    return nil
                }
                return self.pendingFrames.removeFirst()
            }
            guard let frame else { return }
            do {
                try await self.sendFrame(frame)
            } catch {
                self.handleTransportFailure(error)
                return
            }
        }
    }

    private func sendFrame(_ data: Data) async throws {
        let connection = try self.requireConnection()
        try await connection.send(data: data)
    }

    private func sendText(_ text: String) async throws {
        let connection = try self.requireConnection()
        try await connection.send(text: text)
    }

    private func requireConnection() throws -> any GrokSTTWebSocketConnection {
        try self.lock.withLock { () -> (any GrokSTTWebSocketConnection) in
            if self.state == .cancelled {
                throw GrokSTTError.cancelled
            }
            guard let connection = self.connection else {
                throw self.stickyError ?? GrokSTTError.socketClosed(code: 0)
            }
            return connection
        }
    }

    private func closeConnection() {
        self.lock.lock()
        let connection = self.connection
        self.connection = nil
        let receiveTask = self.receiveTask
        self.receiveTask = nil
        self.lock.unlock()
        receiveTask?.cancel()
        connection?.close()
    }

    private func mapError(_ error: Error) -> GrokSTTError {
        GrokSTTTransportErrorMapper.map(error)
    }
}

private nonisolated struct GrokSTTServerEvent: Decodable, Sendable {
    let type: String
    let text: String?
    let start: Double?
    let message: String?
}
