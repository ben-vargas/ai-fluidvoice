import AVFoundation
import CoreMedia
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class GrokMeetingTranscriptionBackendTests: XCTestCase {
    func testDescriptorIsHostedLegacyContractWithGrokLanguages() {
        let descriptor = GrokMeetingTranscriptionBackend.descriptor
        XCTAssertEqual(descriptor.id, .grokSTT)
        XCTAssertEqual(descriptor.execution, .hosted)
        XCTAssertEqual(descriptor.resultContract, .legacyResult)
        XCTAssertTrue(descriptor.supportedLanguageCodes.isSuperset(of: ["en", "es", "fr", "de"]))
    }

    func testPlansNonEnglishMeetingsTheLegacyBackendRejects() throws {
        let backend = GrokMeetingTranscriptionBackend(legacyExecutor: { _, _ in
            throw MeetingProcessingError.noRecoverableAudio
        })
        let request = self.makeRequest(languageCode: "es")
        let plan = try backend.plan(request)
        XCTAssertEqual(plan.backendID, .grokSTT)
        XCTAssertNil(plan.agreementDefect(with: request, descriptor: backend.descriptor))

        let legacy = MeetingLegacyCompatibilityBackend(legacyExecutor: { _, _ in
            throw MeetingProcessingError.noRecoverableAudio
        })
        XCTAssertThrowsError(try legacy.plan(request))
    }

    func testRejectsLanguagesGrokDoesNotSupport() {
        let backend = GrokMeetingTranscriptionBackend(legacyExecutor: { _, _ in
            throw MeetingProcessingError.noRecoverableAudio
        })
        XCTAssertThrowsError(try backend.plan(self.makeRequest(languageCode: "et"))) { error in
            XCTAssertEqual(
                error as? MeetingBackendError,
                .unsupportedLanguage(backend: .grokSTT, languageCode: "et")
            )
        }
    }

    func testDefaultRegistryResolvesTheGrokBackend() throws {
        let backend = try MeetingTranscriptionBackendRegistry.makeDefault().makeBackend(
            id: .grokSTT,
            context: MeetingBackendHostContext(legacyExecutor: { _, _ in
                throw MeetingProcessingError.noRecoverableAudio
            })
        )
        XCTAssertTrue(backend is GrokMeetingTranscriptionBackend)
    }

    func testGrokTakesOnlyMeetingsInItsLanguagesWhileSelected() {
        XCTAssertTrue(GrokMeetingTranscriptionBackend.handles(languageCode: "en", selectedModel: .grokSTT))
        XCTAssertTrue(GrokMeetingTranscriptionBackend.handles(languageCode: "de", selectedModel: .grokSTT))
        XCTAssertTrue(GrokMeetingTranscriptionBackend.handles(languageCode: "uk", selectedModel: .grokSTT))
        // Parakeet transcribes Estonian and Latvian; Grok does not, so those meetings stay local.
        XCTAssertFalse(GrokMeetingTranscriptionBackend.handles(languageCode: "et", selectedModel: .grokSTT))
        XCTAssertFalse(GrokMeetingTranscriptionBackend.handles(languageCode: "lv", selectedModel: .grokSTT))
        XCTAssertFalse(GrokMeetingTranscriptionBackend.handles(languageCode: "", selectedModel: .grokSTT))
        // Another engine never routes a meeting to xAI.
        XCTAssertFalse(GrokMeetingTranscriptionBackend.handles(languageCode: "en", selectedModel: .parakeetTDT))
        XCTAssertFalse(GrokMeetingTranscriptionBackend.handles(languageCode: "en", selectedModel: .fluidParakeetPro))
    }

    func testPipelineRoutesByMeetingLanguageWhileGrokIsSelected() async {
        let settings = SettingsStore.shared
        let previousModel = settings.selectedSpeechModel
        let previousBackend = settings.meetingTranscriptionBackendID
        defer {
            settings.selectedSpeechModel = previousModel
            settings.meetingTranscriptionBackendID = previousBackend
        }
        settings.selectedSpeechModel = .grokSTT
        settings.meetingTranscriptionBackendID = .productionDefault

        // The local backend prepares its diarizer first; the Grok backend never does.
        let localMarker = CocoaError(.userCancelled)
        var localPreparations = 0
        let pipeline = MeetingProcessingPipeline(
            asrServiceProvider: { XCTFail("A meeting in a language Grok lacks must not use the selected engine"); return ASRService() },
            managesModelResidency: false,
            prepareDiarizationModel: { localPreparations += 1; throw localMarker },
            preferredASRModelProvider: { .fluidParakeetPro }
        )
        do {
            _ = try await pipeline.process(
                session: self.makeRequest(languageCode: "et").session,
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Expected the local preparation marker")
        } catch {
            XCTAssertEqual(error as? CocoaError, localMarker)
        }
        XCTAssertEqual(localPreparations, 1)
    }

    // MARK: - Fixtures

    private func makeRequest(languageCode: String) -> MeetingBackendRequest {
        let timebase = MeetingTimebaseMetadata(
            startedHostTime: 0,
            machTimebaseNumerator: 1,
            machTimebaseDenominator: 1,
            firstPresentationTime: nil
        )
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: .onlineCall,
                title: "Grok fixture",
                languageCode: languageCode,
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic-1", displayName: "Mic")
            ),
            timebase: timebase
        )
        let chunk = MeetingAudioChunk(
            id: UUID(),
            sequence: 0,
            relativeFilePath: "tracks/microphone/chunk_0.caf",
            presentationStart: MeetingMediaTime(value: 0, timescale: 1000),
            presentationEnd: MeetingMediaTime(value: 1000, timescale: 1000),
            discontinuities: [],
            sha256: "fixture-0",
            byteCount: 1024,
            finalizationState: .finalized
        )
        session.audioTracks = [
            MeetingAudioTrack(
                id: UUID(),
                kind: .microphone,
                sourceIdentifier: "microphone",
                sourceDisplayName: "microphone",
                format: nil,
                timebase: timebase,
                health: .waiting,
                chunks: [chunk]
            ),
        ]
        return MeetingBackendRequest(
            attemptID: UUID(),
            session: session,
            sessionDirectory: FileManager.default.temporaryDirectory,
            configuration: MeetingFinalProcessingConfiguration(languageCode: languageCode)
        )
    }
}

// MARK: - Live captions

#if arch(arm64)
final class GrokMeetingLiveRecognizerTests: XCTestCase {
    private final class FakeSocket: GrokMeetingCaptionSocket, @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (Double, String, Bool) -> Void)?
        private var frames: [Data] = []
        private var error: GrokSTTError?
        private var queued = 0
        private var cancels = 0
        private let startError: GrokSTTError?

        init(startError: GrokSTTError? = nil) {
            self.startError = startError
        }

        var onUtteranceEvent: (@Sendable (Double, String, Bool) -> Void)? {
            get { self.lock.withLock { self.handler } }
            set { self.lock.withLock { self.handler = newValue } }
        }

        var transportError: GrokSTTError? { self.lock.withLock { self.error } }
        var queuedAudioFrameCount: Int { self.lock.withLock { self.queued } }
        var sentFrames: [Data] { self.lock.withLock { self.frames } }
        var cancelCount: Int { self.lock.withLock { self.cancels } }

        @concurrent func start() async throws {
            if let startError { throw startError }
        }

        func append(pcm16: Data) { self.lock.withLock { self.frames.append(pcm16) } }
        func cancel() { self.lock.withLock { self.cancels += 1 } }
        func fail(_ error: GrokSTTError) { self.lock.withLock { self.error = error } }
        func stall() { self.lock.withLock { self.queued = GrokMeetingLiveRecognizer.maxQueuedFrames + 1 } }

        func emit(start: Double = 0, _ text: String, final: Bool = false) {
            self.onUtteranceEvent?(start, text, final)
        }
    }

    /// Hands out sockets in order and records how each was configured.
    private final class Sockets: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [FakeSocket]
        private var made: [FakeSocket] = []
        private var configurations: [StreamingSTTSessionConfiguration] = []

        init(_ sockets: [FakeSocket]) {
            self.queue = sockets
        }

        var count: Int { self.lock.withLock { self.made.count } }
        var seenConfigurations: [StreamingSTTSessionConfiguration] { self.lock.withLock { self.configurations } }

        func make(_ configuration: StreamingSTTSessionConfiguration) -> any GrokMeetingCaptionSocket {
            self.lock.withLock {
                let socket = self.queue.isEmpty ? FakeSocket() : self.queue.removeFirst()
                self.made.append(socket)
                self.configurations.append(configuration)
                return socket
            }
        }
    }

    private final class Callbacks: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        var all: [String] { self.lock.withLock { self.log } }
        var ends: [String] { self.all.filter { $0.hasPrefix("end:") } }
        func partial(_ text: String) { self.lock.withLock { self.log.append("partial:" + text) } }
        func end(_ text: String) { self.lock.withLock { self.log.append("end:" + text) } }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 100
        func now() -> Double { self.lock.withLock { self.value } }
        func advance(_ seconds: Double) { self.lock.withLock { self.value += seconds } }
    }

    /// Records the waits between connection attempts instead of sleeping through them.
    private final class Waits: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: [Double] = []
        private var cancelsAt: Int?
        var all: [Double] { self.lock.withLock { self.seconds } }
        /// The engine cancels its load task when the meeting stops.
        func cancelOnWait(_ index: Int) { self.lock.withLock { self.cancelsAt = index } }

        func wait(_ seconds: Double) async throws {
            let cancelled = self.lock.withLock { () -> Bool in
                self.seconds.append(seconds)
                return self.cancelsAt == self.seconds.count
            }
            if cancelled { throw CancellationError() }
        }
    }

    private func makeRecognizer(
        _ sockets: Sockets,
        clock: Clock = Clock(),
        waits: Waits = Waits(),
        callbacks: Callbacks
    ) async -> GrokMeetingLiveRecognizer {
        let recognizer = GrokMeetingLiveRecognizer(
            languageCode: "de",
            socketFactory: { sockets.make($0) },
            keyterms: { ["FluidVoice"] },
            uptime: { clock.now() },
            sleep: { try await waits.wait($0) }
        )
        await recognizer.setPartialTranscriptCallback { callbacks.partial($0) }
        await recognizer.setEouCallback { callbacks.end($0) }
        return recognizer
    }

    private func audio(samples: Int) -> AVAudioPCMBuffer {
        // swiftlint:disable:next force_unwrapping
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        // swiftlint:disable:next force_unwrapping
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples))!
        buffer.frameLength = AVAudioFrameCount(samples)
        return buffer
    }

    /// Socket events cross a stream and a task before they are queued, so keep asking the
    /// recognizer the way the engine does until the expected callbacks have arrived.
    private func pump(
        _ recognizer: GrokMeetingLiveRecognizer,
        until done: @escaping () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<400 {
            try await recognizer.processBufferedAudio()
            if done() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Expected callbacks did not arrive", file: file, line: line)
    }

    private func wait(_ done: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        await grokSTTAssertEventually(file: file, line: line, predicate: done)
    }

    func testPrepareConnectsAndAudioGoesOutInWholeFrames() async throws {
        let socket = FakeSocket()
        let sockets = Sockets([socket])
        let recognizer = await self.makeRecognizer(sockets, callbacks: Callbacks())

        try await recognizer.prepareModels()
        XCTAssertEqual(sockets.seenConfigurations, [
            StreamingSTTSessionConfiguration(sampleRate: 16_000, languageCode: "de", keyterms: ["FluidVoice"], interimResults: true),
        ])

        try await recognizer.appendAudio(self.audio(samples: 2500))
        XCTAssertEqual(socket.sentFrames.map(\.count), [GrokSTTAudioConverter.bytesPerFrame])
        try await recognizer.appendAudio(self.audio(samples: 700))
        XCTAssertEqual(socket.sentFrames.count, 2, "The 900 samples left over join the next buffer")
        XCTAssertEqual(sockets.count, 1)
    }

    func testTextReachesTheEngineOnlyWhenItAsksAndOneUtteranceAtATime() async throws {
        let socket = FakeSocket()
        let callbacks = Callbacks()
        let recognizer = await self.makeRecognizer(Sockets([socket]), callbacks: callbacks)
        try await recognizer.prepareModels()

        socket.emit("hello")
        socket.emit("hello there")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(callbacks.all.isEmpty, "Nothing is delivered outside processBufferedAudio")

        try await self.pump(recognizer) { !callbacks.all.isEmpty }
        XCTAssertEqual(callbacks.all.last, "partial:hello there")

        socket.emit("Hello there.", final: true)
        socket.emit(start: 3, "next")
        try await self.pump(recognizer) { !callbacks.ends.isEmpty }
        XCTAssertEqual(callbacks.ends, ["end:Hello there."])
        let afterEnd = callbacks.all.count

        // The engine resets after every utterance; until then nothing else is handed over.
        try await Task.sleep(nanoseconds: 50_000_000)
        try await recognizer.processBufferedAudio()
        XCTAssertEqual(callbacks.all.count, afterEnd)

        await recognizer.reset()
        try await self.pump(recognizer) { callbacks.all.count > afterEnd }
        XCTAssertEqual(callbacks.all.last, "partial:next")
        XCTAssertEqual(socket.cancelCount, 0, "The routine reset after an utterance keeps the socket")
    }

    func testAnUtteranceThatEndsBeforeTheEngineSawItStillOpensFirst() async throws {
        let socket = FakeSocket()
        let callbacks = Callbacks()
        let recognizer = await self.makeRecognizer(Sockets([socket]), callbacks: callbacks)
        try await recognizer.prepareModels()

        // Both events are queued before the engine next asks.
        socket.emit("ok")
        socket.emit("Okay.", final: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await recognizer.processBufferedAudio()
        // The engine dates an utterance from its first partial and drops an end without one.
        XCTAssertEqual(callbacks.all, ["partial:Okay.", "end:Okay."])
    }

    func testAResyncWithAnOpenUtteranceReplacesTheSocketAndAQuietOneKeepsIt() async throws {
        let first = FakeSocket()
        let second = FakeSocket()
        let sockets = Sockets([first, second])
        let callbacks = Callbacks()
        let recognizer = await self.makeRecognizer(sockets, callbacks: callbacks)
        try await recognizer.prepareModels()

        // Warmup: silence in, nothing back. The socket is clean and stays.
        try await recognizer.appendAudio(self.audio(samples: 16_000))
        try await recognizer.processBufferedAudio()
        await recognizer.reset()
        XCTAssertEqual(first.cancelCount, 0)

        first.emit("half a sen")
        try await self.pump(recognizer) { !callbacks.all.isEmpty }
        await recognizer.reset()
        XCTAssertGreaterThan(first.cancelCount, 0, "The server still holds the unfinished utterance")

        try await recognizer.appendAudio(self.audio(samples: 1600))
        await self.wait { sockets.count == 2 }
        first.emit("stale text from the old socket")
        try await Task.sleep(nanoseconds: 30_000_000)
        try await recognizer.processBufferedAudio()
        XCTAssertEqual(callbacks.all, ["partial:half a sen"])
    }

    func testALostSocketClosesTheCaptionAndReconnectsWithoutLosingAudio() async throws {
        let first = FakeSocket()
        let second = FakeSocket()
        let sockets = Sockets([first, second])
        let callbacks = Callbacks()
        let recognizer = await self.makeRecognizer(sockets, callbacks: callbacks)
        try await recognizer.prepareModels()

        first.emit("we should ship on")
        try await self.pump(recognizer) { !callbacks.all.isEmpty }

        first.fail(.socketClosed(code: 1006))
        try await recognizer.appendAudio(self.audio(samples: 1600))
        try await recognizer.processBufferedAudio()
        XCTAssertEqual(callbacks.ends, ["end:we should ship on"], "The caption closes with what arrived")
        await recognizer.reset()

        await self.wait { sockets.count == 2 && second.sentFrames.count == 1 }
        try await recognizer.appendAudio(self.audio(samples: 1600))
        XCTAssertEqual(second.sentFrames.count, 2, "Audio buffered during the reconnect went to the new socket")
    }

    func testAStalledSocketIsTreatedAsLost() async throws {
        let first = FakeSocket()
        let sockets = Sockets([first, FakeSocket()])
        let recognizer = await self.makeRecognizer(sockets, callbacks: Callbacks())
        try await recognizer.prepareModels()

        first.stall()
        try await recognizer.appendAudio(self.audio(samples: 1600))
        XCTAssertGreaterThan(first.cancelCount, 0)
        await self.wait { sockets.count == 2 }
    }

    func testAFailedReconnectIsReportedOnceThenRetriedAfterItsDelay() async throws {
        let first = FakeSocket()
        let third = FakeSocket()
        let sockets = Sockets([first, FakeSocket(startError: .offline), third])
        let clock = Clock()
        let recognizer = await self.makeRecognizer(sockets, clock: clock, callbacks: Callbacks())
        try await recognizer.prepareModels()

        first.fail(.socketClosed(code: 1006))
        try await recognizer.appendAudio(self.audio(samples: 1600))
        await self.wait { sockets.count == 2 }

        // The failure surfaces on the next buffer, once; the engine shows it and resyncs.
        var thrown: [GrokSTTError] = []
        for _ in 0..<50 where thrown.isEmpty {
            do { try await recognizer.appendAudio(self.audio(samples: 160)) } catch { thrown.append(error as? GrokSTTError ?? .cancelled) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(thrown, [.offline])
        try await recognizer.appendAudio(self.audio(samples: 160))
        XCTAssertEqual(sockets.count, 2, "No new attempt before the delay has passed")

        clock.advance(GrokMeetingLiveRecognizer.reconnectDelays[1] + 0.1)
        try await recognizer.appendAudio(self.audio(samples: 160))
        await self.wait { sockets.count == 3 && !third.sentFrames.isEmpty }
    }

    func testAFailureThatRetryingCannotFixStopsCaptions() async throws {
        let first = FakeSocket()
        let sockets = Sockets([first, FakeSocket(startError: .noCredentialConfigured)])
        let clock = Clock()
        let recognizer = await self.makeRecognizer(sockets, clock: clock, callbacks: Callbacks())
        try await recognizer.prepareModels()

        first.fail(.socketClosed(code: 1006))
        try await recognizer.appendAudio(self.audio(samples: 1600))
        await self.wait { sockets.count == 2 }
        var reported = false
        for _ in 0..<50 where !reported {
            do { try await recognizer.appendAudio(self.audio(samples: 160)) } catch { reported = true }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(reported)

        clock.advance(600)
        try await recognizer.appendAudio(self.audio(samples: 1600))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sockets.count, 2, "No further sockets once sign-in is known to be missing")
    }

    func testPrepareSurfacesAFailureWaitingCannotFixAtOnce() async {
        let sockets = Sockets([FakeSocket(startError: .noCredentialConfigured)])
        let waits = Waits()
        let recognizer = await self.makeRecognizer(sockets, waits: waits, callbacks: Callbacks())
        do {
            try await recognizer.prepareModels()
            XCTFail("Expected the sign-in failure")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .noCredentialConfigured)
        }
        XCTAssertEqual(sockets.count, 1)
        XCTAssertTrue(waits.all.isEmpty)
    }

    func testPrepareRetriesAFirstConnectionThatFailedForNow() async throws {
        let working = FakeSocket()
        let sockets = Sockets([FakeSocket(startError: .offline), FakeSocket(startError: .timeout), working])
        let waits = Waits()
        let recognizer = await self.makeRecognizer(sockets, waits: waits, callbacks: Callbacks())

        try await recognizer.prepareModels()
        XCTAssertEqual(sockets.count, 3)
        XCTAssertEqual(waits.all, Array(GrokMeetingLiveRecognizer.reconnectDelays[1...2]))

        try await recognizer.appendAudio(self.audio(samples: 1600))
        XCTAssertEqual(working.sentFrames.count, 1)
    }

    func testPrepareGivesUpAfterItsLastDelay() async {
        let delays = GrokMeetingLiveRecognizer.reconnectDelays
        let sockets = Sockets((0..<delays.count + 3).map { _ in FakeSocket(startError: .offline) })
        let waits = Waits()
        let recognizer = await self.makeRecognizer(sockets, waits: waits, callbacks: Callbacks())
        do {
            try await recognizer.prepareModels()
            XCTFail("Expected the connection failure")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .offline)
        }
        XCTAssertEqual(sockets.count, delays.count)
        XCTAssertEqual(waits.all, Array(delays.dropFirst()))
    }

    func testStoppingTheMeetingEndsTheWaitForAFirstConnection() async {
        let sockets = Sockets([FakeSocket(startError: .offline), FakeSocket()])
        let waits = Waits()
        waits.cancelOnWait(1)
        let recognizer = await self.makeRecognizer(sockets, waits: waits, callbacks: Callbacks())
        do {
            try await recognizer.prepareModels()
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(sockets.count, 1, "No further socket once the load was cancelled")
    }

    func testStoppingARealEngineEndsItsWaitForAFirstConnection() async {
        let sockets = Sockets([FakeSocket(startError: .offline), FakeSocket()])
        let waiting = expectation(description: "the recognizer is waiting to retry")
        let recognizer = GrokMeetingLiveRecognizer(
            languageCode: "en",
            socketFactory: { sockets.make($0) },
            keyterms: { [] },
            // Like the real sleep: it ends only when the engine cancels its load task.
            sleep: { _ in
                waiting.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        )
        let engine = MeetingLiveTrackEngine(kind: .microphone, recognizer: recognizer)
        await engine.configure(
            onPartial: { _, _, _, _, _ in },
            onUtterance: { _, _, _, _, _ in },
            onDegraded: { _, reason in XCTFail("A stopped load is not a failure: \(reason)") },
            onReady: { _ in XCTFail("Captions must not become ready after stop") }
        )
        await engine.start()
        await fulfillment(of: [waiting], timeout: 5)

        let started = Date()
        await engine.stop()
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "stop() cancels the load instead of waiting it out")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(sockets.count, 1, "No further connection attempt after stop")
    }

    func testTheEngineBecomesReadyAfterAFirstConnectionThatFailedForNow() async {
        let working = FakeSocket()
        let sockets = Sockets([FakeSocket(startError: .timeout), working])
        let recognizer = await self.makeRecognizer(sockets, callbacks: Callbacks())
        let engine = MeetingLiveTrackEngine(kind: .microphone, recognizer: recognizer)
        let ready = expectation(description: "captions ready")
        await engine.configure(
            onPartial: { _, _, _, _, _ in },
            onUtterance: { _, _, _, _, _ in },
            onDegraded: { _, reason in XCTFail("Unexpected degradation: \(reason)") },
            onReady: { _ in ready.fulfill() }
        )
        await engine.start()
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(sockets.count, 2)
        XCTAssertEqual(working.cancelCount, 0, "The warmup that follows keeps the socket")
        await engine.stop()
    }

    func testTheEngineReportsAFirstConnectionThatCannotSucceed() async {
        let sockets = Sockets([FakeSocket(startError: .unauthorized)] + (0..<8).map { _ in FakeSocket(startError: .noCredentialConfigured) })
        let recognizer = await self.makeRecognizer(sockets, callbacks: Callbacks())
        let engine = MeetingLiveTrackEngine(kind: .microphone, recognizer: recognizer)
        let failed = expectation(description: "captions could not load")
        await engine.configure(
            onPartial: { _, _, _, _, _ in },
            onUtterance: { _, _, _, _, _ in },
            onDegraded: { _, reason in if reason.hasPrefix("Live captions could not load") { failed.fulfill() } },
            onReady: { _ in XCTFail("Captions must not be shown as ready") }
        )
        await engine.start()
        await fulfillment(of: [failed], timeout: 5)
        await engine.stop()
    }

    func testTheSocketClosesOnceAudioStops() async throws {
        let socket = FakeSocket()
        let clock = Clock()
        let recognizer = await self.makeRecognizer(Sockets([socket]), clock: clock, callbacks: Callbacks())
        try await recognizer.prepareModels()
        try await recognizer.appendAudio(self.audio(samples: 1600))

        clock.advance(GrokMeetingLiveRecognizer.idleCloseSeconds - 1)
        let early = await recognizer.closeIfIdle()
        XCTAssertFalse(early)
        XCTAssertEqual(socket.cancelCount, 0)

        clock.advance(2)
        let closed = await recognizer.closeIfIdle()
        XCTAssertTrue(closed)
        XCTAssertGreaterThan(socket.cancelCount, 0)
    }

    func testFinishReturnsWhatArrivedAndStartsOver() async throws {
        let socket = FakeSocket()
        let callbacks = Callbacks()
        let recognizer = await self.makeRecognizer(Sockets([socket]), callbacks: callbacks)
        try await recognizer.prepareModels()

        socket.emit("a very long")
        try await self.pump(recognizer) { !callbacks.all.isEmpty }
        socket.emit("a very long phrase")
        try await Task.sleep(nanoseconds: 50_000_000)
        let text = try await recognizer.finish()
        XCTAssertEqual(text, "a very long phrase")
        XCTAssertGreaterThan(socket.cancelCount, 0)
    }

    @MainActor
    func testGrokCaptionsOnlyWhileGrokIsSelectedAndKnowsTheLanguage() {
        let settings = SettingsStore.shared
        let previous = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = previous }

        settings.selectedSpeechModel = .grokSTT
        XCTAssertTrue(GrokMeetingCaptions.isGrokSelected, "The key must match the one SettingsStore saves under")
        XCTAssertTrue(GrokMeetingCaptions.areSelected(languageCode: "en"))
        XCTAssertTrue(GrokMeetingCaptions.areSelected(languageCode: "uk"))
        XCTAssertFalse(GrokMeetingCaptions.areSelected(languageCode: "et"))
        XCTAssertNotNil(GrokMeetingCaptions.recognizer(languageCode: "en"))
        XCTAssertNil(GrokMeetingCaptions.recognizer(languageCode: "et"))

        settings.selectedSpeechModel = .parakeetTDT
        XCTAssertFalse(GrokMeetingCaptions.areSelected(languageCode: "en"))
        XCTAssertNil(GrokMeetingCaptions.recognizer(languageCode: "en"))
    }

    func testTheEngineTurnsGrokTextIntoOneTimedUtterance() async throws {
        let socket = FakeSocket()
        let recognizer = await self.makeRecognizer(Sockets([socket]), callbacks: Callbacks())
        try await recognizer.prepareModels()
        let engine = MeetingLiveTrackEngine(kind: .applicationAudio, recognizer: recognizer)

        let partial = expectation(description: "caption in progress")
        partial.assertForOverFulfill = false
        let finished = expectation(description: "one finished caption")
        finished.assertForOverFulfill = true
        await engine.configure(
            onPartial: { _, _, text, _, _ in if text == "good morning" { partial.fulfill() } },
            onUtterance: { kind, _, text, start, end in
                XCTAssertEqual(kind, .applicationAudio)
                XCTAssertEqual(text, "Good morning everyone.")
                XCTAssertLessThanOrEqual(start.seconds, end.seconds)
                finished.fulfill()
            },
            onDegraded: { _, reason in XCTFail("Unexpected degradation: \(reason)") },
            onReady: { _ in }
        )
        await engine.diagnosticInstallCallbacks()

        // The engine reads recognizer text after each buffer it feeds, as during a meeting.
        let feeding = Task {
            for index in 0..<400 where !Task.isCancelled {
                let pts = CMTime(value: CMTimeValue(index * 100), timescale: 1000)
                let sample = MeetingLiveSampleCopy.Sample(
                    buffer: self.audio(samples: 1600),
                    pts: pts,
                    duration: CMTime(value: 100, timescale: 1000)
                )
                await engine.diagnosticConsume(sample)
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        socket.emit("good morning")
        await fulfillment(of: [partial], timeout: 2)
        socket.emit("Good morning everyone.", final: true)
        await fulfillment(of: [finished], timeout: 2)
        feeding.cancel()
        await feeding.value
        XCTAssertFalse(socket.sentFrames.isEmpty, "The engine's audio reached the socket")
        XCTAssertEqual(socket.cancelCount, 0)
        await engine.stop()
    }
}
#endif

// MARK: - Canonical backend

@MainActor
final class GrokMeetingNemotronBackendTests: XCTestCase {
    // MARK: Routing

    func testGrokUsesTheCanonicalBackendWhereverItCanRun() {
        XCTAssertEqual(GrokMeetingBackends.backendID(languageCode: "en", selectedModel: .grokSTT), .grokSTTNemotron)
        XCTAssertEqual(GrokMeetingBackends.backendID(languageCode: "uk", selectedModel: .grokSTT), .grokSTTNemotron)
        // A Grok language upstream's canonical pipeline does not know keeps the in-pipeline workflow.
        XCTAssertEqual(GrokMeetingBackends.backendID(languageCode: "ja", selectedModel: .grokSTT), .grokSTT)
        // A language Grok lacks, or another engine, leaves the meeting to upstream.
        XCTAssertNil(GrokMeetingBackends.backendID(languageCode: "et", selectedModel: .grokSTT))
        XCTAssertNil(GrokMeetingBackends.backendID(languageCode: "en", selectedModel: .fluidParakeetPro))

        XCTAssertTrue(GrokMeetingBackends.canonicalLanguageCodes.isSubset(of: VoiceEngineLanguageCatalog.parakeetV3LanguageIDs))
        XCTAssertTrue(GrokMeetingBackends.canonicalLanguageCodes.isSubset(of: Set(GrokSTTLanguage.codes)))
        XCTAssertTrue(GrokMeetingBackends.diarizesWithNemotron(.grokSTTNemotron))
        XCTAssertFalse(GrokMeetingBackends.diarizesWithNemotron(.grokSTT))
        XCTAssertFalse(GrokMeetingBackends.diarizesWithNemotron(.parakeetNemotron))
        XCTAssertEqual(GrokMeetingBackends.recordedASRModel(for: .grokSTTNemotron), "grok-stt")
        XCTAssertNil(GrokMeetingBackends.recordedASRModel(for: .parakeetNemotron))
    }

    func testDefaultRegistryMakesTheCanonicalGrokBackendUnderItsOwnIdentity() throws {
        let backend = try MeetingTranscriptionBackendRegistry.makeDefault().makeBackend(
            id: .grokSTTNemotron,
            context: MeetingBackendHostContext(legacyExecutor: { _, _ in throw MeetingProcessingError.noRecoverableAudio })
        )
        XCTAssertTrue(backend is GrokMeetingNemotronBackend)
        XCTAssertEqual(backend.descriptor.execution, .hosted)
        XCTAssertEqual(backend.descriptor.resultContract, .canonicalEvidence)
        XCTAssertEqual(backend.descriptor.supportedFinalPrecisions, [.word, .utterance])
    }

    func testAGrokMeetingPreparesTheSpeakerModelBeforePlanning() async {
        let settings = SettingsStore.shared
        let previous = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = previous }
        settings.selectedSpeechModel = .grokSTT

        // Only backends that diarize with Nemotron reach this preparation step.
        let marker = CocoaError(.userCancelled)
        var preparations = 0
        let pipeline = MeetingProcessingPipeline(
            asrServiceProvider: { XCTFail("The canonical Grok backend never loads a local speech model"); return ASRService() },
            managesModelResidency: false,
            prepareDiarizationModel: { preparations += 1; throw marker },
            preferredASRModelProvider: { XCTFail("No local speech model is chosen for a Grok meeting"); return .fluidParakeetPro }
        )
        do {
            _ = try await pipeline.process(
                session: self.makeSession(tracks: [self.makeMicTrack(chunks: [self.makeChunk(start: 100, end: 103)])]),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Expected the preparation marker")
        } catch {
            XCTAssertEqual(error as? CocoaError, marker)
        }
        XCTAssertEqual(preparations, 1)
    }

    // MARK: Plan and execute

    func testPlanCarriesGrokIdentityAndUpstreamsChecks() throws {
        let session = self.makeSession(tracks: [self.makeMicTrack(chunks: [self.makeChunk(start: 100, end: 103)])])
        let backend = self.makeBackend(local: FakeLocalRuntime(), transcriber: { _, _, _ in GrokSTTRESTTranscript(text: "", words: []) })
        let request = self.makeRequest(session: session)
        let plan = try backend.plan(request)
        XCTAssertEqual(plan.backendID, .grokSTTNemotron)
        XCTAssertNil(plan.agreementDefect(with: request, descriptor: backend.descriptor))

        // A language outside the canonical set is refused before anything is uploaded.
        let estonian = self.makeSession(tracks: session.audioTracks, languageCode: "et")
        XCTAssertThrowsError(try backend.plan(self.makeRequest(session: estonian, languageCode: "et"))) { error in
            XCTAssertEqual(error as? MeetingBackendError, .unsupportedLanguage(backend: .grokSTTNemotron, languageCode: "et"))
        }

        // Upstream's planner still requires the local speaker model.
        struct Missing: Error {}
        let unprepared = self.makeBackend(
            local: FakeLocalRuntime(),
            locator: StubLocator(error: Missing()),
            transcriber: { _, _, _ in GrokSTTRESTTranscript(text: "", words: []) }
        )
        XCTAssertThrowsError(try unprepared.plan(request)) { XCTAssertTrue($0 is Missing) }
    }

    func testExecuteReturnsWordEvidenceUnderGrokIdentityThatUpstreamAssembles() async throws {
        let chunk = self.makeChunk(start: 100, end: 103)
        let track = self.makeMicTrack(chunks: [chunk])
        let session = self.makeSession(tracks: [track])
        let local = FakeLocalRuntime()
        let uploads = Uploads()
        let backend = self.makeBackend(local: local, transcriber: { samples, languageCode, keyterms in
            uploads.record(sampleCount: samples.count, languageCode: languageCode, keyterms: keyterms)
            return GrokSTTRESTTranscript(text: "hello there", words: [
                ASRWordTiming(text: "hello", start: 0.2, end: 0.6),
                ASRWordTiming(text: "there", start: 0.7, end: 1.1),
            ])
        })
        let request = self.makeRequest(session: session)
        let plan = try backend.plan(request)
        let manifest = try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: FixtureObserver(results: [MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk.id): self.makeObserved(chunk, duration: 3)]),
            analysisSampleRate: 16_000
        ).build()
        let epoch = try XCTUnwrap(manifest.track(track.id)?.epochs.first)
        local.diarizer.segmentsByEpoch = [epoch.id: [MeetingNemotronSpeakerSegment(slotIndex: 1, start: 0, end: 3)]]

        let outcome = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
        guard case let .canonicalEvidence(bundle) = outcome else { return XCTFail("Expected canonical evidence") }

        XCTAssertEqual(bundle.evidence.backendID, .grokSTTNemotron)
        XCTAssertEqual(bundle.evidence.attemptID, plan.attemptID)
        XCTAssertEqual(bundle.evidence.units.map(\.text), ["hello", "there"])
        XCTAssertTrue(bundle.evidence.units.allSatisfy { $0.precision == .word })
        XCTAssertTrue(bundle.coverageReceipts.allSatisfy { $0.status == .processed })
        XCTAssertEqual(uploads.all.count, 1)
        XCTAssertEqual(uploads.all.first?.sampleCount, 48_000)
        XCTAssertEqual(uploads.all.first?.languageCode, "en")
        XCTAssertEqual(uploads.all.first?.keyterms, ["FluidVoice"])
        XCTAssertEqual(local.diarizationScopes, 1, "Speaker detection stays with the local runtime")
        XCTAssertEqual(local.localASRScopes, 0, "No local speech model is prepared")

        // Upstream's assembler accepts the evidence against this backend's plan and manifest.
        let assembly = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: bundle.evidence,
            coverageReceipts: bundle.coverageReceipts
        ))
        XCTAssertFalse(assembly.segments.isEmpty)
    }

    func testAFailedUploadFailsTheAttemptInsteadOfPublishingAPartialTranscript() async throws {
        let first = self.makeChunk(sequence: 0, start: 100, end: 102)
        let second = self.makeChunk(sequence: 1, start: 105, end: 107)
        let track = self.makeMicTrack(chunks: [first, second])
        let session = self.makeSession(tracks: [track])
        let uploads = Uploads()
        let backend = self.makeBackend(local: FakeLocalRuntime(), transcriber: { samples, languageCode, keyterms in
            uploads.record(sampleCount: samples.count, languageCode: languageCode, keyterms: keyterms)
            throw GrokSTTError.forbidden
        })
        let plan = try backend.plan(self.makeRequest(session: session))
        let manifest = try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: FixtureObserver(results: [
                MeetingAnalysisChunkKey(trackID: track.id, chunkID: first.id): self.makeObserved(first, duration: 2),
                MeetingAnalysisChunkKey(trackID: track.id, chunkID: second.id): self.makeObserved(second, duration: 2),
            ]),
            analysisSampleRate: 16_000
        ).build()
        XCTAssertEqual(manifest.track(track.id)?.epochs.count, 2)

        do {
            _ = try await backend.execute(plan: plan, manifest: manifest, progress: { _ in })
            XCTFail("Expected the upload failure")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .forbidden)
        }
        XCTAssertEqual(uploads.all.count, 1, "The second epoch is not uploaded once the attempt is lost")
    }

    // MARK: Speech session

    func testSessionOffsetsWordsAcrossRequestsAndKeepsThemInsideTheirAudio() async throws {
        let uploads = Uploads()
        var session = self.makeASRSession { samples, _, _ in
            let index = uploads.record(sampleCount: samples.count, languageCode: nil, keyterms: [])
            return GrokSTTRESTTranscript(text: "part\(index)", words: [
                ASRWordTiming(text: "w\(index)", start: 1, end: 2),
                // xAI may report a word slightly past the end of what was sent.
                ASRWordTiming(text: "late\(index)", start: 4.5, end: 9),
            ])
        }
        session.maxRequestSamples = 5 * 16_000
        let output = try await session.transcribeWithTimings([Float](repeating: 0, count: 8 * 16_000))

        XCTAssertEqual(uploads.all.map(\.sampleCount), [80_000, 48_000])
        XCTAssertEqual(output.result.text, "part1 part2")
        XCTAssertEqual(output.words.map(\.text), ["w1", "late1", "w2", "late2"])
        XCTAssertEqual(output.words.map(\.start), [1, 4.5, 6, 8])
        XCTAssertEqual(output.words.map(\.end), [2, 5, 7, 8])
    }

    func testSessionTreatsSilenceAsEmptyAndRetriesWhatWaitingCanFix() async throws {
        let failures = GrokMeetingUploadFailures()
        var calls = 0
        var waits: [Int] = []
        var session = self.makeASRSession(failures: failures) { _, _, _ in
            calls += 1
            switch calls {
            case 1: throw GrokSTTError.emptyTranscript
            case 2: throw GrokSTTError.timeout
            default: return GrokSTTRESTTranscript(text: "recovered", words: [])
            }
        }
        session.retryDelay = { waits.append($0) }

        let silence = try await session.transcribeWithTimings([Float](repeating: 0, count: 16_000))
        XCTAssertEqual(silence.result.text, "")
        XCTAssertTrue(silence.words.isEmpty)

        let retried = try await session.transcribeWithTimings([Float](repeating: 0, count: 16_000))
        XCTAssertEqual(retried.result.text, "recovered")
        XCTAssertEqual(waits, [1])
        XCTAssertNil(failures.first, "A request that succeeded on retry is not a failure")
    }

    func testSessionRecordsALostAttemptAndStopsUploading() async {
        let failures = GrokMeetingUploadFailures()
        var calls = 0
        var session = self.makeASRSession(failures: failures) { _, _, _ in
            calls += 1
            throw GrokSTTError.offline
        }
        session.retryDelay = { _ in }

        for _ in 0..<2 {
            do {
                _ = try await session.transcribeWithTimings([Float](repeating: 0, count: 16_000))
                XCTFail("Expected the upload failure")
            } catch {
                XCTAssertEqual(error as? GrokSTTError, .offline)
            }
        }
        XCTAssertEqual(calls, GrokMeetingASRSession.attempts, "Retried within the first request, then never again")
        XCTAssertEqual(failures.first, .offline)
    }

    func testRESTClientReadsWordTimingsAndDropsUnusableOnes() async throws {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 200, json: [
            "text": "The balance is $167.",
            "duration": 3.45,
            "words": [
                ["text": "The", "start": 0.24, "end": 0.48],
                ["text": "balance", "start": 0.48, "end": 0.96],
                ["text": " ", "start": 1.0, "end": 1.1],
                ["text": "backwards", "start": 2.0, "end": 1.0],
                ["text": "untimed"],
                ["text": "$167.", "start": 1.12, "end": 3.2, "speaker": 0],
            ],
        ])
        let client = GrokSTTRESTClient(resolver: RecordingGrokSTTResolver(), http: http)
        let transcript = try await client.transcribePCMWithWords(
            [Float](repeating: 0.1, count: 1_600),
            languageCode: "en",
            keyterms: [],
            timeout: 30
        )
        XCTAssertEqual(transcript.text, "The balance is $167.")
        XCTAssertEqual(transcript.words.map(\.text), ["The", "balance", "$167."])
        XCTAssertEqual(transcript.words.map(\.start), [0.24, 0.48, 1.12])

        // A transcript without a `words` array is still a transcript.
        http.enqueue(status: 200, json: ["text": "no timings"])
        let untimed = try await client.transcribePCMWithWords([Float](repeating: 0.1, count: 1_600), languageCode: "en", timeout: 30)
        XCTAssertEqual(untimed.text, "no timings")
        XCTAssertTrue(untimed.words.isEmpty)
    }

    // MARK: Fixtures

    private final class Uploads: @unchecked Sendable {
        struct Upload {
            let sampleCount: Int
            let languageCode: String?
            let keyterms: [String]
        }

        private let lock = NSLock()
        private var uploads: [Upload] = []
        var all: [Upload] { self.lock.withLock { self.uploads } }

        @discardableResult
        func record(sampleCount: Int, languageCode: String?, keyterms: [String]) -> Int {
            self.lock.withLock {
                self.uploads.append(Upload(sampleCount: sampleCount, languageCode: languageCode, keyterms: keyterms))
                return self.uploads.count
            }
        }
    }

    private func makeASRSession(
        failures: GrokMeetingUploadFailures = GrokMeetingUploadFailures(),
        transcriber: @escaping GrokMeetingASRSession.Transcriber
    ) -> GrokMeetingASRSession {
        GrokMeetingASRSession(languageCode: "en", keyterms: [], transcriber: transcriber, failures: failures)
    }

    private func makeBackend(
        local: FakeLocalRuntime,
        locator: any MeetingNemotronModelLocating = StubLocator(),
        transcriber: @escaping GrokMeetingASRSession.Transcriber
    ) -> GrokMeetingNemotronBackend {
        GrokMeetingNemotronBackend(
            localRuntimeFactory: { _ in local },
            modelLocator: locator,
            materializer: FakeMaterializer(),
            transcriber: transcriber,
            keyterms: { ["FluidVoice"] }
        )
    }

    private func makeRequest(session: MeetingSession, languageCode: String = "en") -> MeetingBackendRequest {
        MeetingBackendRequest(
            attemptID: UUID(),
            session: session,
            sessionDirectory: FileManager.default.temporaryDirectory,
            configuration: MeetingFinalProcessingConfiguration(languageCode: languageCode)
        )
    }

    private func makeChunk(sequence: Int = 0, start: Double, end: Double) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: UUID(),
            sequence: sequence,
            relativeFilePath: "tracks/microphone/chunk_\(sequence).caf",
            presentationStart: MeetingMediaTime(value: Int64((start * 1000).rounded()), timescale: 1000),
            presentationEnd: MeetingMediaTime(value: Int64((end * 1000).rounded()), timescale: 1000),
            discontinuities: [],
            sha256: String(repeating: "a", count: 64),
            byteCount: 1024,
            finalizationState: .finalized
        )
    }

    private func makeObserved(_ chunk: MeetingAudioChunk, duration: Double) -> MeetingChunkObservationResult {
        .observed(MeetingChunkObservedAudio(
            byteCount: chunk.byteCount,
            sha256: chunk.sha256,
            decoded: MeetingChunkDecodedFacts(
                sampleRate: 16_000,
                channelCount: 1,
                frameCount: Int64((duration * 16_000).rounded()),
                durationSeconds: duration,
                codecPriming: .measuredFrames(0),
                processingFormatDescription: "fixture"
            )
        ))
    }

    private func makeMicTrack(chunks: [MeetingAudioChunk]) -> MeetingAudioTrack {
        let timebase = MeetingTimebaseMetadata(startedHostTime: 7, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        return MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "microphone",
            sourceDisplayName: "microphone",
            format: nil,
            timebase: timebase,
            health: .waiting,
            chunks: chunks,
            captureMethod: .voiceProcessing,
            captureEras: [MeetingCaptureEra(
                method: .voiceProcessing,
                deviceUID: "mic-a",
                deviceName: "mic-a",
                roleAtElection: .unknown,
                echoProtection: .voiceProcessed,
                startSeconds: 100
            )]
        )
    }

    private func makeSession(tracks: [MeetingAudioTrack], languageCode: String = "en") -> MeetingSession {
        let timebase = MeetingTimebaseMetadata(startedHostTime: 7, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: .inRoom,
                title: "Grok canonical fixture",
                languageCode: languageCode,
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic-a", displayName: "Mic")
            ),
            timebase: timebase
        )
        session.audioTracks = tracks
        return session
    }

    private struct FixtureObserver: MeetingChunkAudioObserving {
        let results: [MeetingAnalysisChunkKey: MeetingChunkObservationResult]

        func observe(chunk: MeetingAudioChunk, trackID: MeetingAudioTrackID) -> MeetingChunkObservationResult {
            self.results[MeetingAnalysisChunkKey(trackID: trackID, chunkID: chunk.id)] ?? .failed(.unreadable, detail: "no fixture observation")
        }
    }
}

/// The local runtime as the Grok backend may use it: speaker detection and voice matching.
private final nonisolated class FakeLocalRuntime: MeetingParakeetNemotronRunning, @unchecked Sendable {
    final nonisolated class Diarizer: MeetingNemotronDiarizerFactory, @unchecked Sendable {
        struct Session: MeetingNemotronDiarizerSession {
            let segments: [MeetingNemotronSpeakerSegment]
            func diarize(samples _: [Float]) async throws -> [MeetingNemotronSpeakerSegment] { self.segments }
        }

        var segmentsByEpoch: [MeetingAnalysisEpochID: [MeetingNemotronSpeakerSegment]] = [:]

        func makeDiarizer(epoch: MeetingAnalysisEpochID) async throws -> any MeetingNemotronDiarizerSession {
            Session(segments: self.segmentsByEpoch[epoch] ?? [])
        }
    }

    let diarizer = Diarizer()
    private(set) var diarizationScopes = 0
    private(set) var localASRScopes = 0

    func withNemotronDiarization(
        artifact _: MeetingNemotronModelArtifact,
        _ body: nonisolated(nonsending) @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult
    ) async throws -> MeetingNemotronPhaseResult {
        self.diarizationScopes += 1
        return try await body(self.diarizer)
    }

    func withPreparedASR(
        attemptID _: UUID,
        configuration _: MeetingFinalProcessingConfiguration,
        body _: nonisolated(nonsending) @escaping @Sendable (any MeetingParakeetASRSession) async throws -> MeetingParakeetPhaseResult
    ) async throws -> MeetingParakeetPhaseResult {
        self.localASRScopes += 1
        throw MeetingProcessingError.noRecoverableAudio
    }
}

private final nonisolated class FakeMaterializer: MeetingEpochAudioMaterializing, @unchecked Sendable {
    func materialize(
        epoch: MeetingAnalysisEpochRecord,
        track: MeetingAnalysisTrackManifest,
        manifest _: MeetingAnalysisManifest,
        sessionDirectory _: URL
    ) async throws -> MeetingMaterializedEpoch {
        var cursor = 0
        var ranges: [MeetingMaterializedSpanSamples] = []
        for spanID in epoch.spanIDs {
            guard let span = track.spans.first(where: { $0.id == spanID }) else { continue }
            let count = max(1, Int((span.analysisInterval.duration * 16_000).rounded()))
            ranges.append(MeetingMaterializedSpanSamples(spanID: spanID, sampleRange: cursor..<(cursor + count)))
            cursor += count
        }
        return MeetingMaterializedEpoch(
            epochID: epoch.id,
            samples: [Float](repeating: 0, count: cursor),
            sampleRate: 16_000,
            spanSamples: ranges
        )
    }
}

private final nonisolated class StubLocator: MeetingNemotronModelLocating, @unchecked Sendable {
    private let error: (any Error)?
    private let artifact = MeetingNemotronModelArtifact(
        packageURL: URL(fileURLWithPath: "/tmp/stub-nemotron.mlpackage"),
        totalByteCount: 1,
        fileCount: 1,
        manifestSHA256: "stub",
        entryMetadataSHA256: "stub"
    )

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func locate() throws -> MeetingNemotronModelArtifact {
        if let error { throw error }
        return self.artifact
    }

    func recheck(_ artifact: MeetingNemotronModelArtifact) throws -> MeetingNemotronModelArtifact {
        if let error { throw error }
        return artifact
    }
}
