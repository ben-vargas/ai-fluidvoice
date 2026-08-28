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

    private enum OutboundItem {
        case frame(Data)
        case text(String, CheckedContinuation<Void, Error>)
    }

    private let configuration: StreamingSTTSessionConfiguration
    private let resolver: any GrokSTTCredentialResolving
    private let transport: any GrokSTTWebSocketTransporting
    private let cliSocketEnabled: Bool
    private let createdBudget: TimeInterval
    private let doneTimeout: TimeInterval
    private let lock = NSLock()

    private var assembler = GrokSTTTranscriptAssembler()
    private var state: State = .idle
    private var stickyError: GrokSTTError?
    private var handoffSamples: [Float] = []
    private var outbound: [OutboundItem] = []
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
    private var senderRunning = false

    init(
        configuration: StreamingSTTSessionConfiguration,
        resolver: any GrokSTTCredentialResolving,
        transport: any GrokSTTWebSocketTransporting = GrokSTTURLSessionWebSocketTransport(),
        cliSocketEnabled: Bool = SettingsStore.SpeechModel.grokSTTCLISocketEnabled,
        createdBudget: TimeInterval = GrokSTTWebSocketSession.createdBudget,
        doneTimeout: TimeInterval = GrokSTTWebSocketSession.doneTimeout
    ) {
        self.configuration = configuration
        self.resolver = resolver
        self.transport = transport
        self.cliSocketEnabled = cliSocketEnabled
        self.createdBudget = createdBudget
        self.doneTimeout = doneTimeout
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
        self.lock.withLock {
            self.outbound.reduce(0) { count, item in
                if case .frame = item { return count + 1 }
                return count
            }
        }
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

    #if DEBUG
    func debugBackdateConnectStart(by interval: TimeInterval) {
        self.lock.withLock {
            let started = self.connectStartedAt ?? Date()
            self.connectStartedAt = started.addingTimeInterval(-interval)
        }
    }
    #endif

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
            let state = self.state
            self.lock.unlock()
            #if DEBUG
            switch state {
            case .finishing, .complete, .cancelled, .failed:
                assertionFailure("append(pcm16:) after finish/cancel is illegal (state=\(state.rawValue))")
            default:
                break
            }
            #endif
            return
        }
        self.outbound.append(.frame(pcm16))
        self.appendedFrameCount += 1
        let shouldKick = !self.senderRunning
        if shouldKick {
            self.senderRunning = true
        }
        self.lock.unlock()
        if shouldKick {
            Task.detached { [weak self] in
                await self?.runOutboundSender()
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
        let outboundWaiters = self.abortOutboundLocked()
        let created = self.createdWaiters
        self.createdWaiters = []
        let finishers = self.finishWaiters
        self.finishWaiters = []
        let connection = self.connection
        self.connection = nil
        let receiveTask = self.receiveTask
        self.receiveTask = nil
        self.lock.unlock()

        outboundWaiters.forEach { $0.resume(throwing: GrokSTTError.cancelled) }
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
        let outboundWaiters = self.abortOutboundLocked()
        let created = self.createdWaiters
        self.createdWaiters = []
        let finishers = self.finishWaiters
        self.finishWaiters = []
        self.lock.unlock()
        outboundWaiters.forEach { $0.resume(throwing: error) }
        created.forEach { $0.resume(throwing: error) }
        finishers.forEach { $0.resume(throwing: error) }
        if close {
            self.closeConnection()
        }
    }

    private func waitUntilCreated() async throws {
        let (state, sticky) = self.lock.withLock { (self.state, self.stickyError) }
        switch state {
        case .streaming, .finishing, .complete:
            return
        case .cancelled:
            throw GrokSTTError.cancelled
        default:
            break
        }
        if let sticky { throw sticky }

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
                    try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    return false
                }
                let created = try await group.next()!
                if !created {
                    self.fail(.timeout, close: true)
                }
                group.cancelAll()
                if !created {
                    throw GrokSTTError.timeout
                }
            }
        } catch let error as GrokSTTError {
            throw error
        } catch is CancellationError {
            throw self.lock.withLock({ self.stickyError }) ?? GrokSTTError.cancelled
        } catch {
            throw self.mapError(error)
        }
    }

    private func awaitCreatedGate() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.lock.lock()
                if Task.isCancelled {
                    self.lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
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
        } onCancel: {
            self.lock.lock()
            let waiters = self.createdWaiters
            self.createdWaiters = []
            self.lock.unlock()
            waiters.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    private func remainingCreatedBudget() -> TimeInterval {
        let started = self.lock.withLock { self.connectStartedAt } ?? Date()
        return self.createdBudget - Date().timeIntervalSince(started)
    }

    private func flushHandoffIfNeeded() async throws {
        let samples: [Float] = self.lock.withLock {
            let copy = self.handoffSamples
            self.handoffSamples = []
            return copy
        }
        guard !samples.isEmpty else { return }
        let frameSize = GrokSTTAudioConverter.samplesPerFrame
        var frames: [Data] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + frameSize, samples.count)
            frames.append(GrokSTTAudioConverter.pcm16LE(fromFloat32: samples[offset..<end]))
            offset = end
        }
        self.lock.lock()
        for frame in frames {
            self.outbound.append(.frame(frame))
        }
        let shouldKick = !self.senderRunning
        if shouldKick {
            self.senderRunning = true
        }
        self.lock.unlock()
        if shouldKick {
            Task.detached { [weak self] in
                await self?.runOutboundSender()
            }
        }
    }

    private func sendAudioDone() async throws {
        let already = self.lock.withLock { self.audioDoneSent }
        if already { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.lock.lock()
            if self.audioDoneSent {
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
            if self.state == .streaming || self.state == .waitCreated {
                self.state = .finishing
            }
            self.outbound.append(.text(#"{"type":"audio.done"}"#, continuation))
            let shouldKick = !self.senderRunning
            if shouldKick {
                self.senderRunning = true
            }
            self.lock.unlock()
            if shouldKick {
                Task.detached { [weak self] in
                    await self?.runOutboundSender()
                }
            }
        }
    }

    private func waitForDone() async throws -> String {
        enum DoneWait: Sendable {
            case text(String)
            case timedOut
        }

        do {
            return try await withThrowingTaskGroup(of: DoneWait.self) { group in
                group.addTask {
                    .text(try await self.awaitDoneGate())
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.doneTimeout * 1_000_000_000))
                    return .timedOut
                }
                let first = try await group.next()!
                switch first {
                case let .text(text):
                    group.cancelAll()
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        self.fail(.timeout, close: true)
                        throw GrokSTTError.timeout
                    }
                    self.lock.withLock {
                        if self.state != .cancelled {
                            self.state = .complete
                        }
                    }
                    self.resumeFinishWaiters(.success(text))
                    return text
                case .timedOut:
                    let assembled = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if assembled.isEmpty {
                        self.fail(.timeout, close: true)
                        group.cancelAll()
                        throw GrokSTTError.timeout
                    }
                    self.lock.withLock {
                        if self.state != .cancelled {
                            self.state = .complete
                        }
                    }
                    self.resumeFinishWaiters(.success(assembled))
                    self.closeConnection()
                    group.cancelAll()
                    return assembled
                }
            }
        } catch let error as GrokSTTError {
            if error == .timeout {
                let assembled = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !assembled.isEmpty {
                    self.lock.withLock {
                        if self.state != .cancelled {
                            self.state = .complete
                        }
                    }
                    self.resumeFinishWaiters(.success(assembled))
                    self.closeConnection()
                    return assembled
                }
            }
            throw error
        } catch is CancellationError {
            throw self.lock.withLock({ self.stickyError }) ?? GrokSTTError.cancelled
        } catch {
            throw self.mapError(error)
        }
    }

    private func awaitDoneGate() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                self.lock.lock()
                if Task.isCancelled {
                    self.lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
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
        } onCancel: {
            self.lock.lock()
            let waiters = self.finishWaiters
            self.finishWaiters = []
            self.lock.unlock()
            waiters.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    private func resumeFinishWaiters(_ result: Result<String, Error>) {
        self.lock.lock()
        let waiters = self.finishWaiters
        self.finishWaiters = []
        self.lock.unlock()
        waiters.forEach { $0.resume(with: result) }
    }

    private func runOutboundSender() async {
        while true {
            enum Work {
                case idle
                case frame(Data)
                case text(String, CheckedContinuation<Void, Error>)
            }

            let work: Work = self.lock.withLock {
                if self.state == .cancelled || self.state == .failed
                    || (self.stickyError != nil && self.audioDoneSent == false)
                {
                    self.senderRunning = false
                    return .idle
                }
                guard let item = self.outbound.first else {
                    self.senderRunning = false
                    return .idle
                }
                self.outbound.removeFirst()
                switch item {
                case let .frame(data):
                    return .frame(data)
                case let .text(text, continuation):
                    return .text(text, continuation)
                }
            }

            switch work {
            case .idle:
                return
            case let .frame(data):
                do {
                    try await self.sendFrame(data)
                } catch {
                    self.handleTransportFailure(error)
                    return
                }
            case let .text(text, continuation):
                do {
                    try await self.sendText(text)
                    let accepted: Result<Void, Error> = self.lock.withLock {
                        if self.state == .cancelled {
                            return .failure(GrokSTTError.cancelled)
                        }
                        if let error = self.stickyError, self.audioDoneSent == false {
                            return .failure(error)
                        }
                        self.audioDoneSent = true
                        if self.state == .streaming || self.state == .waitCreated {
                            self.state = .finishing
                        }
                        return .success(())
                    }
                    continuation.resume(with: accepted)
                    if case .failure = accepted {
                        return
                    }
                } catch {
                    continuation.resume(throwing: self.mapError(error))
                    self.handleTransportFailure(error)
                    return
                }
            }
        }
    }

    /// Caller must hold `lock`.
    private func abortOutboundLocked() -> [CheckedContinuation<Void, Error>] {
        var waiters: [CheckedContinuation<Void, Error>] = []
        for item in self.outbound {
            if case let .text(_, continuation) = item {
                waiters.append(continuation)
            }
        }
        self.outbound.removeAll()
        self.senderRunning = false
        return waiters
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
