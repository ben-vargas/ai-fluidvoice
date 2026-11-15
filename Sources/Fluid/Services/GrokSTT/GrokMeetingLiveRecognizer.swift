import AVFoundation
import Foundation

/// The part of a Grok streaming session that meeting captions use. `GrokSTTWebSocketSession` is
/// the production one; tests use a fake.
nonisolated protocol GrokMeetingCaptionSocket: AnyObject, Sendable {
    /// Called once per `transcript.partial`, in order: the piece's `start`, its text, and whether
    /// it closes the utterance.
    var onUtteranceEvent: (@Sendable (_ start: Double, _ text: String, _ isUtteranceFinal: Bool) -> Void)? { get set }
    var transportError: GrokSTTError? { get }
    var queuedAudioFrameCount: Int { get }
    @concurrent func start() async throws
    func append(pcm16: Data)
    func cancel()
}

extension GrokSTTWebSocketSession: GrokMeetingCaptionSocket {}

/// Decides when a meeting's live captions come from Grok instead of the local caption model.
/// Callable from any thread: the caption coordinator is not main-actor bound, and `SettingsStore` is.
nonisolated enum GrokMeetingCaptions {
    /// The key `SettingsStore.selectedSpeechModel` saves under.
    static let selectedSpeechModelDefaultsKey = "SelectedSpeechModel"

    static var isGrokSelected: Bool {
        UserDefaults.standard.string(forKey: self.selectedSpeechModelDefaultsKey) == SettingsStore.SpeechModel.grokSTT.rawValue
    }

    /// Grok captions a meeting only while it is the selected engine and it accepts the meeting's
    /// language, the same rule that sends the final transcript to Grok. Every other meeting keeps
    /// upstream's local captions, and its audio stays on the Mac.
    static func areSelected(languageCode: String) -> Bool {
        self.isGrokSelected && GrokSTTLanguage.normalized(languageCode) != nil
    }

    #if arch(arm64)
    /// `nil` leaves the engine on its local recognizer.
    static func recognizer(languageCode: String) -> (any MeetingLiveRecognizer)? {
        guard self.areSelected(languageCode: languageCode) else { return nil }
        return GrokMeetingLiveRecognizer(languageCode: GrokSTTLanguage.normalized(languageCode))
    }
    #endif
}

#if arch(arm64)
/// Live meeting captions from xAI's streaming endpoint, one instance per audio track.
///
/// `MeetingLiveTrackEngine` was written for a local model, which only produces text while it is
/// asked to decode. This keeps that contract: socket events are queued and handed to the engine
/// only inside `processBufferedAudio`, at most one finished utterance per call, and nothing more
/// until the engine has reset. So the engine's own bookkeeping never sees an out-of-turn callback.
///
/// The socket is replaced, not repaired. If it fails, the caption on screen is closed with the text
/// that arrived, audio is buffered for a few seconds, and a new socket picks up from there.
actor GrokMeetingLiveRecognizer: MeetingLiveRecognizer {
    typealias SocketFactory = @Sendable (StreamingSTTSessionConfiguration) -> any GrokMeetingCaptionSocket
    typealias KeytermProvider = @Sendable () async -> [String]

    /// Audio kept while a socket connects. Older audio is dropped.
    static let maxBufferedSamples = GrokSTTAudioConverter.sampleRate * 10
    /// This many unsent 100 ms frames means the socket has stalled.
    static let maxQueuedFrames = 100
    /// Capture delivers audio without pause, so this much silence from the engine means it stopped.
    static let idleCloseSeconds: Double = 5
    /// Wait before each reconnect attempt. Running out of entries ends the attempts.
    static let reconnectDelays: [Double] = [0, 1, 2, 5, 15, 30]
    /// Events waiting for the engine. More than this means nobody is reading them.
    static let maxQueuedEvents = 512

    private enum Event {
        case piece(start: Double, text: String)
        /// `nil` closes the utterance with whatever pieces arrived (the socket was lost).
        case utteranceEnd(String?)
    }

    private let languageCode: String?
    private let socketFactory: SocketFactory
    private let keyterms: KeytermProvider
    private let uptime: @Sendable () -> Double
    private let sleep: @Sendable (Double) async throws -> Void

    private var eouCallback: (@Sendable (String) -> Void)?
    private var partialCallback: (@Sendable (String) -> Void)?

    private var socket: (any GrokMeetingCaptionSocket)?
    private var connecting: (any GrokMeetingCaptionSocket)?
    /// Changes whenever the current socket is dropped, so its late events and connects are ignored.
    private var generation = 0
    private var connectTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    private var unsent: [Float] = []
    private var events: [Event] = []
    private var assembler = GrokSTTTranscriptAssembler()
    /// The engine has been given a partial for the utterance in progress.
    private var engineHasOpenUtterance = false
    /// A finished utterance was handed over; the engine resets before it takes anything else.
    private var awaitingResetAfterEOU = false

    private var failedConnects = 0
    private var nextConnectUptime: Double = 0
    private var failureToReport: GrokSTTError?
    private var hasGivenUp = false
    private var lastAppendUptime: Double = 0

    init(
        languageCode: String?,
        socketFactory: @escaping SocketFactory = { GrokSTTWebSocketSession(configuration: $0, resolver: GrokSTTCredentialResolver.shared) },
        keyterms: @escaping KeytermProvider = { await GrokSTTKeytermBuilder.terms() },
        uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.languageCode = languageCode
        self.socketFactory = socketFactory
        self.keyterms = keyterms
        self.uptime = uptime
        self.sleep = sleep
    }

    deinit {
        self.socket?.cancel()
        self.connecting?.cancel()
        self.connectTask?.cancel()
        self.eventTask?.cancel()
        self.idleTask?.cancel()
    }

    // MARK: - MeetingLiveRecognizer

    /// There is no model to load. Connecting here makes a missing or rejected sign-in show up as
    /// "Live captions could not load" before the meeting relies on them.
    ///
    /// The engine never feeds a recognizer whose load failed, so nothing later could reconnect it.
    /// A failure that waiting can fix is therefore retried here, on the same schedule as a
    /// reconnect, and the engine cancelling its load (the meeting stopped) ends the wait.
    func prepareModels() async throws {
        var failures = 0
        while self.socket == nil {
            try Task.checkCancellation()
            do {
                try await self.openSocket()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failure = GrokSTTTransportErrorMapper.map(error)
                failures += 1
                guard failure.isRetryable, failures < Self.reconnectDelays.count else { throw failure }
                GrokSTTLog.info("meeting_captions connect failed attempt=\(failures) error=\(String(describing: failure))")
                try await self.sleep(Self.reconnectDelays[failures])
            }
        }
        if Task.isCancelled {
            // Stopped while the socket was opening: nothing will feed or close it.
            self.dropSocket()
            throw CancellationError()
        }
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer) async throws {
        let now = self.uptime()
        self.lastAppendUptime = now
        self.startIdleWatchIfNeeded()
        if let failure = self.failureToReport {
            // Once per outage: the engine shows that captions hit an error and resyncs.
            self.failureToReport = nil
            throw failure
        }
        guard !self.hasGivenUp else { return }
        if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            self.unsent.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        if let socket = self.socket {
            if socket.transportError == nil, socket.queuedAudioFrameCount <= Self.maxQueuedFrames {
                self.sendWholeFrames(to: socket)
                return
            }
            GrokSTTLog.info("meeting_captions socket lost; reconnecting")
            self.enqueue(.utteranceEnd(nil))
            self.dropSocket()
        }
        if self.unsent.count > Self.maxBufferedSamples {
            self.unsent.removeFirst(self.unsent.count - Self.maxBufferedSamples)
        }
        self.reconnectIfDue(now: now)
    }

    /// Hands queued socket events to the engine: the latest partial, or one finished utterance.
    func processBufferedAudio() async throws {
        guard !self.awaitingResetAfterEOU else { return }
        var latestPartial: String?
        while !self.events.isEmpty {
            switch self.events.removeFirst() {
            case let .piece(start, text):
                self.assembler.record(start: start, text: text)
                let transcript = self.assembler.transcript
                if !transcript.isEmpty { latestPartial = transcript }
            case let .utteranceEnd(text):
                let pieces = self.assembler.transcript
                self.assembler = GrokSTTTranscriptAssembler()
                let final = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let utterance = final.isEmpty ? pieces : final
                guard !utterance.isEmpty else { continue }
                // The engine dates an utterance from its first partial, so it must have seen one.
                if !self.engineHasOpenUtterance { self.partialCallback?(utterance) }
                self.engineHasOpenUtterance = false
                self.awaitingResetAfterEOU = true
                self.eouCallback?(utterance)
                return
            }
        }
        if let latestPartial {
            self.engineHasOpenUtterance = true
            self.partialCallback?(latestPartial)
        }
    }

    /// The engine gave up waiting for a phrase to end. Return what arrived and start over.
    func finish() async throws -> String {
        for event in self.events {
            if case let .piece(start, text) = event { self.assembler.record(start: start, text: text) }
        }
        let text = self.assembler.transcript
        self.discardUtteranceState()
        self.dropSocket()
        self.unsent.removeAll()
        return text
    }

    func reset() async {
        if self.awaitingResetAfterEOU {
            // The engine's routine reset after an utterance. The socket is already on the next one.
            self.awaitingResetAfterEOU = false
            return
        }
        // Warmup, stop, dropped audio or an error. Text the server still holds for an unfinished
        // utterance no longer matches the audio that follows, so that socket cannot be reused.
        let serverHoldsText = self.engineHasOpenUtterance || !self.events.isEmpty || !self.assembler.transcript.isEmpty
        self.discardUtteranceState()
        if serverHoldsText {
            self.dropSocket()
            self.unsent.removeAll()
        }
    }

    func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        self.eouCallback = callback
    }

    func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) async {
        self.partialCallback = callback
    }

    // MARK: - Socket

    private func openSocket() async throws {
        let generation = self.generation
        let terms = await self.keyterms()
        guard generation == self.generation else { throw CancellationError() }
        let socket = self.socketFactory(StreamingSTTSessionConfiguration(
            sampleRate: GrokSTTAudioConverter.sampleRate,
            languageCode: self.languageCode,
            keyterms: terms,
            interimResults: true
        ))
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        socket.onUtteranceEvent = { start, text, isUtteranceFinal in
            continuation.yield(isUtteranceFinal ? .utteranceEnd(text) : .piece(start: start, text: text))
        }
        self.connecting = socket
        do {
            try await socket.start()
        } catch {
            if self.connecting === socket { self.connecting = nil }
            socket.onUtteranceEvent = nil
            socket.cancel()
            throw error
        }
        if self.connecting === socket { self.connecting = nil }
        guard generation == self.generation else {
            socket.onUtteranceEvent = nil
            socket.cancel()
            throw CancellationError()
        }
        self.socket = socket
        self.failedConnects = 0
        self.eventTask = Task { [weak self] in
            for await event in stream {
                await self?.receive(event, generation: generation)
            }
        }
        self.sendWholeFrames(to: socket)
    }

    private func receive(_ event: Event, generation: Int) {
        guard generation == self.generation else { return }
        self.enqueue(event)
    }

    private func enqueue(_ event: Event) {
        self.events.append(event)
        if self.events.count > Self.maxQueuedEvents {
            self.events.removeFirst(self.events.count - Self.maxQueuedEvents)
        }
    }

    private func sendWholeFrames(to socket: any GrokMeetingCaptionSocket) {
        let frame = GrokSTTAudioConverter.samplesPerFrame
        let whole = self.unsent.count / frame * frame
        guard whole > 0 else { return }
        var offset = 0
        while offset < whole {
            socket.append(pcm16: GrokSTTAudioConverter.pcm16LE(fromFloat32: self.unsent[offset..<(offset + frame)]))
            offset += frame
        }
        self.unsent.removeFirst(whole)
    }

    private func dropSocket() {
        self.generation += 1
        for socket in [self.socket, self.connecting] {
            socket?.onUtteranceEvent = nil
            socket?.cancel()
        }
        self.socket = nil
        self.connecting = nil
        self.eventTask?.cancel()
        self.eventTask = nil
        self.connectTask?.cancel()
        self.connectTask = nil
    }

    private func discardUtteranceState() {
        self.events.removeAll()
        self.assembler = GrokSTTTranscriptAssembler()
        self.engineHasOpenUtterance = false
        self.awaitingResetAfterEOU = false
    }

    private func reconnectIfDue(now: Double) {
        guard self.connectTask == nil, now >= self.nextConnectUptime else { return }
        let generation = self.generation
        self.connectTask = Task { [weak self] in
            await self?.reconnect(generation: generation)
        }
    }

    private func reconnect(generation: Int) async {
        do {
            try await self.openSocket()
            if generation == self.generation { self.connectTask = nil }
        } catch {
            // A drop while connecting has already replaced or cleared the task.
            guard generation == self.generation else { return }
            self.connectTask = nil
            let failure = GrokSTTTransportErrorMapper.map(error)
            self.failedConnects += 1
            if self.failedConnects == 1 { self.failureToReport = failure }
            if failure.isRetryable, self.failedConnects < Self.reconnectDelays.count {
                self.nextConnectUptime = self.uptime() + Self.reconnectDelays[self.failedConnects]
                GrokSTTLog.info("meeting_captions reconnect failed attempt=\(self.failedConnects) error=\(String(describing: failure))")
            } else {
                self.hasGivenUp = true
                self.unsent.removeAll()
                GrokSTTLog.error("meeting_captions stopped error=\(String(describing: failure))")
            }
        }
    }

    // MARK: - Idle

    private func startIdleWatchIfNeeded() {
        guard self.idleTask == nil else { return }
        self.idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, await !self.closeIfIdle() else { return }
            }
        }
    }

    /// Closes the socket once the engine has stopped feeding audio. Returns whether it closed.
    /// The engine has no "meeting ended" call for a recognizer; this is how the socket ends.
    func closeIfIdle() -> Bool {
        guard self.uptime() - self.lastAppendUptime >= Self.idleCloseSeconds else { return false }
        self.idleTask = nil
        self.discardUtteranceState()
        self.dropSocket()
        self.unsent.removeAll()
        return true
    }
}
#endif
