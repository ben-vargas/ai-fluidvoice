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

    private func makeRecognizer(
        _ sockets: Sockets,
        clock: Clock = Clock(),
        callbacks: Callbacks
    ) async -> GrokMeetingLiveRecognizer {
        let recognizer = GrokMeetingLiveRecognizer(
            languageCode: "de",
            socketFactory: { sockets.make($0) },
            keyterms: { ["FluidVoice"] },
            uptime: { clock.now() }
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

    func testPrepareSurfacesAConnectionFailure() async {
        let recognizer = await self.makeRecognizer(Sockets([FakeSocket(startError: .unauthorized)]), callbacks: Callbacks())
        do {
            try await recognizer.prepareModels()
            XCTFail("Expected the sign-in failure")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .unauthorized)
        }
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
