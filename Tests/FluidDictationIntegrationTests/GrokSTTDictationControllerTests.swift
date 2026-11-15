@testable import FluidVoice_Debug
import ApplicationServices
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

// MARK: - Retry

@MainActor
final class GrokSTTRetryCenterTests: XCTestCase {
    private let configuration = GrokSTTDictationController.Configuration(languageCode: "en", keyterms: [])
    private let samples = [Float](repeating: 0.1, count: 1600)
    private let field = TypingService.CapturedFocusTarget(pid: 1, window: nil, element: AXUIElementCreateSystemWide())

    /// ContentView's reprocess path, reduced to how it uses a delivery: one decision before
    /// typing, `allowsOutput` as the validity check while the paste is prepared, `didType` when
    /// the paste command is out, `isSuperseded` before teardown, and then upstream's delayed
    /// clipboard settlement, which asks `allowsOutput` again after reprocess has returned.
    @MainActor
    private final class Reprocess {
        var texts: [String] = []
        var steps: [String] = []
        private(set) var delivery: GrokSTTRecoveredDelivery?
        /// What ContentView adds: a newer recording's overlay, and Escape.
        var newerOverlay = false
        var escapePressed = false
        var beforeTyping: () -> Void = {}
        var whilePasting: () -> Void = {}
        var beforeTeardown: () -> Void = {}

        func install(on center: GrokSTTRetryCenter) {
            center.deliverRecoveredDictation = { text, delivery in
                self.texts.append(text)
                let final = text + " (cleaned)"
                let delivery = delivery.restricted(
                    supersededWhen: { self.newerOverlay },
                    cancelledWhen: { self.escapePressed }
                )
                self.delivery = delivery
                await Task.yield()
                self.beforeTyping()
                let decision = delivery.decision(for: final)
                self.steps.append("decision:\(decision)")
                if decision == .abandon { return }
                if decision == .type {
                    await Task.yield()
                    self.whilePasting()
                    if delivery.allowsOutput(final) {
                        delivery.didType()
                        self.steps.append("pasted")
                    } else {
                        self.steps.append("paste declined")
                    }
                }
                self.beforeTeardown()
                if delivery.isSuperseded { return self.steps.append("no teardown") }
                // Teardown clears the recording mode, exactly as Escape would.
                self.escapePressed = true
                self.steps.append("teardown")
            }
        }

        /// Upstream settles the clipboard and verifies the paste after reprocess has returned.
        var settlementSeesValidOutput: Bool {
            self.delivery?.allowsOutput("") ?? false
        }
    }

    private func makeCenter(
        transcribe: @escaping GrokSTTRetryCenter.Transcriber = { _, _ in "hello world" },
        focusedAtClick: Bool = true,
        stillFocused: @escaping () -> Bool = { true }
    ) -> GrokSTTRetryCenter {
        let field = self.field
        return GrokSTTRetryCenter(
            transcribe: transcribe,
            showsPanel: false,
            captureFocus: { focusedAtClick ? field : nil },
            isFocusActive: { _ in stillFocused() }
        )
    }

    private func failOrdinaryDictation(on center: GrokSTTRetryCenter) {
        center.retain(samples: self.samples, error: .timeout, configuration: self.configuration)
        center.noteEmptyResult(isNormalRoute: true, wasEdit: false, wasCommand: false, wasPromptTest: false, wasCancelled: false)
    }

    private func retryAndSettle(_ center: GrokSTTRetryCenter) async {
        center.retry()
        await center.retryInFlight?.value
        for _ in 0..<10 { await Task.yield() }
    }

    func testRecoveredOrdinaryDictationIsTypedIntoTheFieldFromTheRetryClick() async {
        let reprocess = Reprocess()
        let center = self.makeCenter()
        reprocess.install(on: center)

        self.failOrdinaryDictation(on: center)
        await self.retryAndSettle(center)

        XCTAssertEqual(reprocess.texts.map { $0.lowercased() }, ["hello world"])
        XCTAssertEqual(reprocess.steps, ["decision:type", "pasted", "teardown"])
        XCTAssertNil(center.pending)
        XCTAssertNil(center.recoveredTextForCopy)
        XCTAssertFalse(center.isRetrying)
    }

    func testAPastedDeliveryStaysValidForClipboardSettlementAfterReprocessReturns() async {
        var focused = true
        let reprocess = Reprocess()
        let center = self.makeCenter(stillFocused: { focused })
        reprocess.install(on: center)

        self.failOrdinaryDictation(on: center)
        await self.retryAndSettle(center)
        XCTAssertEqual(reprocess.steps, ["decision:type", "pasted", "teardown"])

        // By now reprocess has cleared the recording mode and the retry center has let go of the
        // delivery. The user moves on, and even starts the next recording.
        focused = false
        XCTAssertTrue(reprocess.settlementSeesValidOutput, "The clipboard backup and paste check still apply")
        center.recordingWillStart()
        reprocess.newerOverlay = true
        XCTAssertTrue(reprocess.settlementSeesValidOutput)
        XCTAssertNil(center.recoveredTextForCopy, "A pasted delivery is never offered for copying afterwards")
    }

    func testADeliveryThatWasNotPastedIsNotValidForSettlement() async {
        let reprocess = Reprocess()
        let center = self.makeCenter(focusedAtClick: false)
        reprocess.install(on: center)

        self.failOrdinaryDictation(on: center)
        await self.retryAndSettle(center)

        XCTAssertEqual(reprocess.steps, ["decision:keepWithoutTyping", "teardown"])
        XCTAssertFalse(reprocess.settlementSeesValidOutput)
    }

    func testOnlyAnOrdinaryUncancelledDictationIsEverMarked() {
        let cases: [(normal: Bool, edit: Bool, command: Bool, promptTest: Bool, cancelled: Bool)] = [
            (false, false, false, false, false), // history-only or onboarding route
            (true, true, false, false, false), // Edit
            (true, false, true, false, false), // Command
            (true, false, false, true, false), // prompt test, even after its editor closed
            (true, false, false, false, true), // Escape while the final transcript was pending
        ]
        for item in cases {
            let center = self.makeCenter()
            center.retain(samples: self.samples, error: .timeout, configuration: self.configuration)
            center.noteEmptyResult(
                isNormalRoute: item.normal,
                wasEdit: item.edit,
                wasCommand: item.command,
                wasPromptTest: item.promptTest,
                wasCancelled: item.cancelled
            )
            XCTAssertEqual(center.pending?.isPlainDictation, false, "\(item)")
            center.clear()
        }
    }

    func testUnmarkedRecordingIsOfferedForCopyAndNeverDelivered() async {
        let reprocess = Reprocess()
        let center = self.makeCenter(transcribe: { _, _ in "delete everything" })
        reprocess.install(on: center)

        center.retain(samples: self.samples, error: .timeout, configuration: self.configuration)
        await self.retryAndSettle(center)

        XCTAssertTrue(reprocess.texts.isEmpty)
        XCTAssertEqual(center.recoveredTextForCopy?.lowercased(), "delete everything")
        XCTAssertNil(center.pending)
    }

    func testTextIsKeptForCopyWhenTheFieldLostFocusDuringCleanup() async {
        var focused = true
        let reprocess = Reprocess()
        reprocess.beforeTyping = { focused = false }
        let center = self.makeCenter(stillFocused: { focused })
        reprocess.install(on: center)

        self.failOrdinaryDictation(on: center)
        await self.retryAndSettle(center)

        XCTAssertEqual(reprocess.steps, ["decision:keepWithoutTyping", "teardown"])
        XCTAssertEqual(center.recoveredTextForCopy?.lowercased(), "hello world (cleaned)")
    }

    func testAPasteInProgressIsDeclinedWhenTheFieldLosesFocusAndStaysDeclined() async {
        var focused = true
        let reprocess = Reprocess()
        reprocess.whilePasting = { focused = false }
        // Focus coming back must not revive a delivery whose text is already offered for copying.
        reprocess.beforeTeardown = { focused = true }
        let center = self.makeCenter(stillFocused: { focused })
        reprocess.install(on: center)

        self.failOrdinaryDictation(on: center)
        await self.retryAndSettle(center)

        XCTAssertEqual(reprocess.steps, ["decision:type", "paste declined", "teardown"])
        XCTAssertEqual(center.recoveredTextForCopy?.lowercased(), "hello world (cleaned)")
        XCTAssertFalse(reprocess.settlementSeesValidOutput)
    }

    func testEscapeDuringCleanupKeepsTheTextInHistoryWithoutTyping() async {
        let reprocess = Reprocess()
        reprocess.beforeTyping = { reprocess.escapePressed = true }
        let center = self.makeCenter()
        reprocess.install(on: center)

        self.failOrdinaryDictation(on: center)
        await self.retryAndSettle(center)

        XCTAssertEqual(reprocess.steps, ["decision:keepWithoutTyping", "teardown"])
        XCTAssertNil(center.recoveredTextForCopy)
    }

    func testDismissingTheCopyOfferDoesNotStrandTheOverlay() async {
        var focused = true
        let reprocess = Reprocess()
        let center = self.makeCenter(stillFocused: { focused })
        reprocess.beforeTyping = { focused = false }
        // The user dismisses the Copy panel while reprocess is still finishing.
        reprocess.beforeTeardown = { center.clear() }
        reprocess.install(on: center)

        self.failOrdinaryDictation(on: center)
        await self.retryAndSettle(center)

        XCTAssertEqual(reprocess.steps, ["decision:keepWithoutTyping", "teardown"])
        XCTAssertNil(center.recoveredTextForCopy)
    }

    func testTextIsNotTypedWhenNoFieldWasFocusedAtTheRetryClick() async {
        let reprocess = Reprocess()
        let center = self.makeCenter(focusedAtClick: false)
        reprocess.install(on: center)

        self.failOrdinaryDictation(on: center)
        await self.retryAndSettle(center)

        XCTAssertEqual(reprocess.steps, ["decision:keepWithoutTyping", "teardown"])
        XCTAssertEqual(center.recoveredTextForCopy?.lowercased(), "hello world (cleaned)")
    }

    func testANewRecordingDuringCleanupAbandonsTheDelivery() async {
        let reprocess = Reprocess()
        let center = self.makeCenter()
        // ASRService.start calls this for every capture, on any engine.
        reprocess.beforeTyping = { center.recordingWillStart() }
        reprocess.install(on: center)

        self.failOrdinaryDictation(on: center)
        await self.retryAndSettle(center)

        XCTAssertEqual(reprocess.steps, ["decision:abandon"])
        XCTAssertNil(center.recoveredTextForCopy)
    }

    func testANewRecordingWhilePastingDeclinesThePasteAndLeavesItsOverlayAlone() async {
        let reprocess = Reprocess()
        let center = self.makeCenter()
        reprocess.whilePasting = {
            center.recordingWillStart()
            reprocess.newerOverlay = true
        }
        reprocess.install(on: center)

        self.failOrdinaryDictation(on: center)
        await self.retryAndSettle(center)

        XCTAssertEqual(reprocess.steps, ["decision:type", "paste declined", "no teardown"])
    }

    func testARecordingThatStartsAsTheUploadFinishesKeepsReprocessFromStarting() async {
        let reprocess = Reprocess()
        var center: GrokSTTRetryCenter?
        // The capture starts in the same main-actor turn the upload returns in.
        center = self.makeCenter(transcribe: { _, _ in
            Task { @MainActor in center?.recordingWillStart() }
            return "too late"
        })
        guard let center else { return XCTFail("No center") }
        reprocess.install(on: center)

        self.failOrdinaryDictation(on: center)
        await self.retryAndSettle(center)

        XCTAssertTrue(reprocess.texts.isEmpty, "Reprocess stops a running capture, so it must not start")
    }

    func testANewRecordingDuringTheUploadDiscardsTheRetry() async {
        let gate = TestGate()
        let reprocess = Reprocess()
        let center = self.makeCenter(transcribe: { _, _ in
            await gate.wait()
            return "too late"
        })
        reprocess.install(on: center)

        self.failOrdinaryDictation(on: center)
        center.retry()
        let upload = center.retryInFlight
        center.recordingWillStart()
        gate.signal()
        await upload?.value
        for _ in 0..<10 { await Task.yield() }

        XCTAssertTrue(reprocess.texts.isEmpty)
        XCTAssertNil(center.recoveredTextForCopy)
    }

    func testMarkSurvivesAFailedRetryAndDoesNotLeakIntoTheNextRecording() async {
        var attempts = 0
        let reprocess = Reprocess()
        let center = self.makeCenter(transcribe: { _, _ in
            attempts += 1
            if attempts == 1 { throw GrokSTTError.timeout }
            return "second try"
        })
        reprocess.install(on: center)

        self.failOrdinaryDictation(on: center)
        await self.retryAndSettle(center)
        XCTAssertEqual(center.pending?.isPlainDictation, true, "A failed retry keeps the recording and its mark")
        await self.retryAndSettle(center)
        XCTAssertEqual(reprocess.texts.map { $0.lowercased() }, ["second try"])
        XCTAssertEqual(reprocess.steps, ["decision:type", "pasted", "teardown"])

        // A later failed recording starts unmarked.
        center.retain(samples: self.samples, error: .timeout, configuration: self.configuration)
        XCTAssertEqual(center.pending?.isPlainDictation, false)
        center.clear()
    }

    func testNotingAnEmptyResultWithNothingRetainedDoesNothing() {
        let center = self.makeCenter()
        center.noteEmptyResult(isNormalRoute: true, wasEdit: false, wasCommand: false, wasPromptTest: false, wasCancelled: false)
        XCTAssertNil(center.pending)
    }

    func testReprocessWithoutARetryIsUnrestricted() {
        // Upstream's own "reprocess last dictation" passes no delivery.
        let delivery = GrokSTTRecoveredDelivery.unrestricted
        XCTAssertEqual(delivery.decision(for: "text"), .type)
        XCTAssertTrue(delivery.allowsOutput("text"))
        XCTAssertFalse(delivery.isSuperseded)
    }
}
