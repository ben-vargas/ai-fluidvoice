@testable import FluidVoice_Debug
import Foundation
import XCTest

final class GrokSTTDictationControllerTests: XCTestCase {
    private let configuration = GrokSTTDictationController.Configuration(languageCode: "en", keyterms: ["FluidVoice"])

    func testPreviewSendsOnlyWholeUnsentFramesAndReturnsSocketTranscript() async throws {
        let factory = FakeDictationSessionFactory()
        let controller = factory.makeController()

        // First poll opens the session; nothing can be sent before `transcript.created`.
        _ = await controller.preview(self.samples(1_000), generation: 1, configuration: self.configuration)
        let session = try XCTUnwrap(factory.sessions.first)
        await self.waitUntilStarted(session)

        session.transcript = "hello"
        let text = await controller.preview(self.samples(3_500), generation: 1, configuration: self.configuration)
        XCTAssertEqual(text, "hello")
        XCTAssertEqual(session.appendedByteCounts, [3_200, 3_200])

        _ = await controller.preview(self.samples(4_900), generation: 1, configuration: self.configuration)
        XCTAssertEqual(session.appendedByteCounts, [3_200, 3_200, 3_200])
        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertEqual(session.configuration.languageCode, "en")
        XCTAssertEqual(session.configuration.keyterms, ["FluidVoice"])
    }

    func testPreviewPausesWhileSendQueueIsBacklogged() async throws {
        let factory = FakeDictationSessionFactory()
        let controller = factory.makeController()
        _ = await controller.preview([], generation: 1, configuration: self.configuration)
        let session = try XCTUnwrap(factory.sessions.first)
        await self.waitUntilStarted(session)

        session.queuedAudioFrameCount = GrokSTTDictationController.sendQueuePauseLimit + 1
        _ = await controller.preview(self.samples(16_000), generation: 1, configuration: self.configuration)
        XCTAssertTrue(session.appendedByteCounts.isEmpty)

        session.queuedAudioFrameCount = 0
        _ = await controller.preview(self.samples(16_000), generation: 1, configuration: self.configuration)
        XCTAssertEqual(session.appendedByteCounts.count, 10)
    }

    func testFinishSendsRemainderIncludingPartialFrame() async throws {
        let factory = FakeDictationSessionFactory()
        let controller = factory.makeController()
        _ = await controller.preview([], generation: 1, configuration: self.configuration)
        let session = try XCTUnwrap(factory.sessions.first)
        await self.waitUntilStarted(session)
        _ = await controller.preview(self.samples(1_600), generation: 1, configuration: self.configuration)

        session.finishResult = .success("final text")
        let text = try await controller.finish(self.samples(2_000), generation: 1, configuration: self.configuration)

        XCTAssertEqual(text, "final text")
        XCTAssertEqual(session.appendedByteCounts, [3_200, 800])
        XCTAssertTrue(session.handoff.isEmpty)
        XCTAssertTrue(session.didCancel, "the socket is released once the final text arrives")
        XCTAssertEqual(factory.restCalls, 0)
    }

    func testFinishHandsOffWholeRecordingWhenNothingWasSent() async throws {
        let factory = FakeDictationSessionFactory()
        factory.startDelayNanoseconds = 200_000_000
        let controller = factory.makeController()
        _ = await controller.preview(self.samples(800), generation: 1, configuration: self.configuration)
        let session = try XCTUnwrap(factory.sessions.first)
        session.finishResult = .success("short")

        let text = try await controller.finish(self.samples(2_400), generation: 1, configuration: self.configuration)

        XCTAssertEqual(text, "short")
        XCTAssertEqual(session.handoff.count, 2_400)
        XCTAssertTrue(session.appendedByteCounts.isEmpty)
    }

    func testFinishFallsBackToRESTWhenSocketFails() async throws {
        let factory = FakeDictationSessionFactory()
        factory.restResult = .success("from rest")
        let controller = factory.makeController()
        _ = await controller.preview([], generation: 1, configuration: self.configuration)
        let session = try XCTUnwrap(factory.sessions.first)
        session.finishResult = .failure(GrokSTTError.socketClosed(code: 1006))

        let text = try await controller.finish(self.samples(3_200), generation: 1, configuration: self.configuration)

        XCTAssertEqual(text, "from rest")
        XCTAssertEqual(factory.restCalls, 1)
        XCTAssertEqual(factory.restSampleCounts, [3_200])
        XCTAssertEqual(factory.restConfigurations, [self.configuration])
    }

    func testFinishFallsBackToRESTWhenSocketTextIsBlank() async throws {
        let factory = FakeDictationSessionFactory()
        factory.restResult = .success("rest text")
        let controller = factory.makeController()
        _ = await controller.preview([], generation: 1, configuration: self.configuration)
        try XCTUnwrap(factory.sessions.first).finishResult = .success("   ")

        let text = try await controller.finish(self.samples(1_600), generation: 1, configuration: self.configuration)
        XCTAssertEqual(text, "rest text")
        XCTAssertEqual(factory.restCalls, 1)
    }

    func testRESTFailureIsRethrown() async throws {
        let factory = FakeDictationSessionFactory()
        factory.restResult = .failure(GrokSTTError.offline)
        let controller = factory.makeController()
        _ = await controller.preview([], generation: 1, configuration: self.configuration)
        try XCTUnwrap(factory.sessions.first).finishResult = .failure(GrokSTTError.offline)

        do {
            _ = try await controller.finish(self.samples(1_600), generation: 1, configuration: self.configuration)
            XCTFail("expected an error")
        } catch let error as GrokSTTError {
            XCTAssertEqual(error, .offline)
        }
    }

    func testNewGenerationTearsDownPreviousSession() async throws {
        let factory = FakeDictationSessionFactory()
        let controller = factory.makeController()
        _ = await controller.preview([], generation: 1, configuration: self.configuration)
        _ = await controller.preview([], generation: 2, configuration: self.configuration)

        XCTAssertEqual(factory.sessions.count, 2)
        XCTAssertTrue(factory.sessions[0].didCancel)
        XCTAssertFalse(factory.sessions[1].didCancel)
    }

    func testCancelIgnoresStaleGeneration() async throws {
        let factory = FakeDictationSessionFactory()
        let controller = factory.makeController()
        _ = await controller.preview([], generation: 2, configuration: self.configuration)

        await controller.cancel(generation: 1)
        XCTAssertFalse(try XCTUnwrap(factory.sessions.first).didCancel)

        await controller.cancel(generation: 2)
        XCTAssertTrue(try XCTUnwrap(factory.sessions.first).didCancel)
    }

    func testCancelledFinishDoesNotFallBackToREST() async throws {
        let factory = FakeDictationSessionFactory()
        factory.restResult = .success("should not be used")
        let controller = factory.makeController()
        _ = await controller.preview([], generation: 1, configuration: self.configuration)
        let session = try XCTUnwrap(factory.sessions.first)
        session.finishDelayNanoseconds = 200_000_000
        session.finishResult = .failure(GrokSTTError.cancelled)

        let finishing = Task { try await controller.finish(self.samples(1_600), generation: 1, configuration: self.configuration) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await controller.cancel(generation: 1)

        do {
            _ = try await finishing.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(factory.restCalls, 0)
        }
    }

    // MARK: - Helpers

    private func samples(_ count: Int) -> [Float] {
        Array(repeating: 0.1, count: count)
    }

    private func waitUntilStarted(_ session: FakeDictationSession, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !session.didStart {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        // Give the controller's detached start task a moment to mark the session created.
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(session.didStart, "session never started", file: file, line: line)
    }
}

// MARK: - Test doubles

private final class FakeDictationSessionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var _sessions: [FakeDictationSession] = []
    private var _restSampleCounts: [Int] = []
    private var _restConfigurations: [GrokSTTDictationController.Configuration] = []
    var startDelayNanoseconds: UInt64 = 0
    var restResult: Result<String, Error> = .failure(GrokSTTError.offline)

    var sessions: [FakeDictationSession] { self.lock.withLock { self._sessions } }
    var restSampleCounts: [Int] { self.lock.withLock { self._restSampleCounts } }
    var restConfigurations: [GrokSTTDictationController.Configuration] { self.lock.withLock { self._restConfigurations } }
    var restCalls: Int { self.restSampleCounts.count }

    func makeController() -> GrokSTTDictationController {
        GrokSTTDictationController(
            makeSession: { configuration in
                let session = FakeDictationSession(configuration: configuration, startDelayNanoseconds: self.startDelayNanoseconds)
                self.lock.withLock { self._sessions.append(session) }
                return session
            },
            transcribeREST: { samples, configuration in
                let result = self.lock.withLock {
                    self._restSampleCounts.append(samples.count)
                    self._restConfigurations.append(configuration)
                    return self.restResult
                }
                return try result.get()
            }
        )
    }
}

private final class FakeDictationSession: StreamingTranscriptionSession, @unchecked Sendable {
    private let lock = NSLock()
    let configuration: StreamingSTTSessionConfiguration
    private let startDelayNanoseconds: UInt64

    private var _transcript = ""
    private var _appended: [Int] = []
    private var _handoff: [Float] = []
    private var _didStart = false
    private var _didCancel = false
    private var _queued = 0
    private var _finishResult: Result<String, Error> = .success("")
    private var _finishDelay: UInt64 = 0

    var transportError: GrokSTTError? { nil }
    var onPartial: (@MainActor (String) -> Void)?

    init(configuration: StreamingSTTSessionConfiguration, startDelayNanoseconds: UInt64) {
        self.configuration = configuration
        self.startDelayNanoseconds = startDelayNanoseconds
    }

    var transcript: String {
        get { self.lock.withLock { self._transcript } }
        set { self.lock.withLock { self._transcript = newValue } }
    }

    var appendedByteCounts: [Int] { self.lock.withLock { self._appended } }
    var handoff: [Float] { self.lock.withLock { self._handoff } }
    var didStart: Bool { self.lock.withLock { self._didStart } }
    var didCancel: Bool { self.lock.withLock { self._didCancel } }

    var queuedAudioFrameCount: Int {
        get { self.lock.withLock { self._queued } }
        set { self.lock.withLock { self._queued = newValue } }
    }

    var finishResult: Result<String, Error> {
        get { self.lock.withLock { self._finishResult } }
        set { self.lock.withLock { self._finishResult = newValue } }
    }

    var finishDelayNanoseconds: UInt64 {
        get { self.lock.withLock { self._finishDelay } }
        set { self.lock.withLock { self._finishDelay = newValue } }
    }

    @concurrent func start() async throws {
        if self.startDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: self.startDelayNanoseconds)
        }
        self.lock.withLock { self._didStart = true }
    }

    func append(pcm16: Data) {
        self.lock.withLock { self._appended.append(pcm16.count) }
    }

    func handoffUnsentPCM(_ samples: [Float]) {
        self.lock.withLock { self._handoff = samples }
    }

    @concurrent func finish() async throws -> String {
        let delay = self.finishDelayNanoseconds
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        return try self.finishResult.get()
    }

    func cancel() {
        self.lock.withLock { self._didCancel = true }
    }
}
