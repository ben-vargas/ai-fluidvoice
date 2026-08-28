@testable import FluidVoice_Debug
import XCTest

@MainActor
final class GrokSTTASRServiceSessionTests: XCTestCase {
    func testStartReturnsWithoutAwaitingCreatedAndStopHandoffsEntirePCM() async {
        let session = GrokSTTFakeSession(
            configuration: .init(createdDelay: 0.4, transcriptOnFinish: "hello")
        )
        let provider = makeGrokSTTProvider(session: session)
        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = provider
        asr.testStreamingSessionFactory = { _ in session }

        let startedAt = Date()
        let outcome = await asr.start()
        XCTAssertEqual(outcome, .started)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.2)
        XCTAssertFalse(asr.debugCreatedReceived)

        let pcm = [Float](repeating: 0.1, count: 2_400)
        asr.debugAppendPCM(pcm)
        let text = await asr.stop()

        XCTAssertEqual(asr.debugAudioBufferCount, 0)
        XCTAssertEqual(session.handoffCallCount, 1)
        XCTAssertEqual(session.handoffPCM, pcm)
        XCTAssertEqual(session.appendCallCount, 0, "stop must not append in waitCreated")
        XCTAssertGreaterThanOrEqual(session.appendedSampleCount, pcm.count)
        XCTAssertTrue(session.audioDoneSent)
        XCTAssertEqual(text, ASRService.applySpokenPunctuationFormatting("hello"))
        XCTAssertEqual(asr.lastStopOutcome, .success)
    }

    func testCancelDuringPumpAwaitsPumpBeforeClearingBuffer() async {
        let session = GrokSTTFakeSession(configuration: .init(createdDelay: 0, blockAppend: true))
        let provider = makeGrokSTTProvider(session: session)
        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = provider
        asr.testStreamingSessionFactory = { _ in session }

        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        asr.debugAppendPCM([Float](repeating: 0.2, count: 1_600))

        let blocked = await waitUntil(timeout: 1) { session.isAppendBlocked }
        XCTAssertTrue(blocked)
        XCTAssertGreaterThan(asr.debugAudioBufferCount, 0)

        await asr.stopWithoutTranscription()
        XCTAssertEqual(asr.debugAudioBufferCount, 0)
        XCTAssertFalse(session.audioDoneSent)
        XCTAssertEqual(session.cancelCallCount, 1)
    }

    func testCreatedDelayedWhileRecordingPumpsFromSampleZeroOnce() async {
        let session = GrokSTTFakeSession(
            configuration: .init(createdDelay: 0.25, transcriptOnFinish: "later")
        )
        let provider = makeGrokSTTProvider(session: session)
        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = provider
        asr.testStreamingSessionFactory = { _ in session }

        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        let pcm = [Float](repeating: 0.15, count: 6_400)
        asr.debugAppendPCM(pcm)

        let created = await waitUntil(timeout: 1) { asr.debugCreatedReceived && session.appendCallCount > 0 }
        XCTAssertTrue(created)

        let appendsBeforeStop = session.appendCallCount
        let text = await asr.stop()
        XCTAssertEqual(text, ASRService.applySpokenPunctuationFormatting("later"))
        XCTAssertEqual(session.handoffCallCount, 0)
        XCTAssertGreaterThan(appendsBeforeStop, 0)
        XCTAssertEqual(session.appendedSampleCount, pcm.count)
    }

    func testMakeStreamingSessionThrowKeepsCaptureAndSkipsFinish() async {
        let provider = makeGrokSTTProvider(configured: false)
        provider.setSessionFactory { _ in throw GrokSTTError.offline }
        let restCalls = TestCounter()
        provider.setRestFinalHandler { _, _ in
            restCalls.increment()
            return ASRTranscriptionResult(text: "should-not-run", confidence: 1)
        }
        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = provider
        asr.testStreamingSessionFactory = { _ in throw GrokSTTError.offline }

        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        XCTAssertTrue(asr.isCloudSessionActive)
        XCTAssertEqual(asr.debugSessionTransportError, .offline)
        XCTAssertTrue(
            DictationOverlayStopPolicy.shouldHideOverlayOnStop(
                isNormalRoute: true,
                wasRewriteMode: false,
                wasCommandMode: false,
                isPromptTestActive: false,
                shouldUseAIOnStop: false,
                spokenSendEnabled: false,
                isCloudSessionActive: asr.isCloudSessionActive,
                hasPendingSTTRetry: asr.hasPendingSTTRetry
            ) == false
        )

        asr.debugAppendPCM([Float](repeating: 0.1, count: 1_600))
        let text = await asr.stop()
        XCTAssertEqual(text, "")
        XCTAssertEqual(restCalls.count, 0)
        XCTAssertTrue(asr.hasPendingSTTRetry)
        XCTAssertEqual(asr.lastStopOutcome, .failed)
        XCTAssertTrue(asr.showError)
    }

    func testMakeStreamingSessionThrowRESTWhenCredentialExists() async {
        let provider = makeGrokSTTProvider(configured: true)
        provider.setSessionFactory { _ in throw GrokSTTError.timeout }
        provider.setRestFinalHandler { samples, _ in
            XCTAssertEqual(samples.count, 800)
            return ASRTranscriptionResult(text: "rested", confidence: 1)
        }
        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = provider
        asr.testStreamingSessionFactory = { _ in throw GrokSTTError.timeout }

        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        asr.debugAppendPCM([Float](repeating: 0.1, count: 800))
        let text = await asr.stop()
        XCTAssertEqual(text, ASRService.applySpokenPunctuationFormatting("rested"))
        XCTAssertFalse(asr.hasPendingSTTRetry)
    }

    func testPreDoneDropDoesNotInsertAssemblerPartials() async {
        let session = GrokSTTFakeSession(configuration: .init(createdDelay: 0, transcriptOnFinish: "partial"))
        let provider = makeGrokSTTProvider(configured: true, session: session)
        provider.setRestFinalHandler { _, _ in
            throw GrokSTTError.offline
        }
        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = provider
        asr.testStreamingSessionFactory = { _ in session }

        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        asr.debugAppendPCM([Float](repeating: 0.1, count: 1_600))
        _ = await waitUntil(timeout: 1) { session.appendCallCount > 0 }
        session.recordPartial(start: 0, text: "should not insert")
        session.fail(.socketClosed(code: 1006))

        let text = await asr.stop()
        XCTAssertEqual(text, "")
        XCTAssertTrue(asr.hasPendingSTTRetry)
        XCTAssertEqual(asr.debugGrokRetryStore.pending?.error, .offline)
    }

    func testFinishThrowBeforeAudioDoneDoesNotInsertPartials() async {
        let session = GrokSTTFakeSession(
            configuration: .init(createdDelay: 0, failBeforeAudioDone: .socketClosed(code: 1006))
        )
        let provider = makeGrokSTTProvider(configured: true, session: session)
        provider.setRestFinalHandler { _, _ in throw GrokSTTError.offline }
        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = provider
        asr.testStreamingSessionFactory = { _ in session }

        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        asr.debugAppendPCM([Float](repeating: 0.1, count: 1_600))
        _ = await waitUntil(timeout: 1) { asr.debugCreatedReceived }
        session.recordPartial(start: 0, text: "partial-must-not-insert")
        XCTAssertNil(asr.debugSessionTransportError)

        let text = await asr.stop()
        XCTAssertEqual(text, "")
        XCTAssertFalse(session.audioDoneSent)
        XCTAssertTrue(asr.hasPendingSTTRetry)
        XCTAssertNotEqual(
            text,
            ASRService.applySpokenPunctuationFormatting("partial-must-not-insert")
        )
    }

    func testRESTFallbackDoesNotUseSwitchedLocalProvider() async {
        let session = GrokSTTFakeSession(
            configuration: .init(failBeforeAudioDone: .timeout)
        )
        let grok = makeGrokSTTProvider(configured: true, session: session)
        let grokREST = TestCounter()
        grok.setRestFinalHandler { samples, _ in
            grokREST.increment()
            XCTAssertEqual(samples.count, 1_600)
            return ASRTranscriptionResult(text: "grok-rest", confidence: 1)
        }
        let local = StubLocalTranscriptionProvider()
        local.transcribeFinalText = "LOCAL"

        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = grok
        asr.testStreamingSessionFactory = { _ in session }
        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        asr.debugAppendPCM([Float](repeating: 0.1, count: 1_600))
        _ = await waitUntil(timeout: 1) { asr.debugCreatedReceived }

        asr.testTranscriptionProviderOverride = local
        asr.testStreamingSessionFactory = nil

        let text = await asr.stop()
        XCTAssertEqual(local.transcribeFinalCount, 0)
        XCTAssertEqual(grokREST.count, 1)
        XCTAssertEqual(text, ASRService.applySpokenPunctuationFormatting("grok-rest"))
        XCTAssertFalse(asr.hasPendingSTTRetry)
    }

    func testRetryAfterEngineSwitchDoesNotRunLocalProvider() async {
        let session = GrokSTTFakeSession(
            configuration: .init(failBeforeAudioDone: .offline)
        )
        let grok = makeGrokSTTProvider(configured: true, session: session)
        grok.setRestFinalHandler { _, _ in throw GrokSTTError.offline }
        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = grok
        asr.testStreamingSessionFactory = { _ in session }
        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        asr.debugAppendPCM([Float](repeating: 0.1, count: 800))
        _ = await asr.stop()
        XCTAssertTrue(asr.hasPendingSTTRetry)

        let local = StubLocalTranscriptionProvider()
        asr.testTranscriptionProviderOverride = local
        XCTAssertTrue(asr.hasPendingSTTRetry)
        grok.setRestFinalHandler { samples, _ in
            XCTAssertEqual(samples.count, 800)
            return ASRTranscriptionResult(text: "grok-retry", confidence: 1)
        }
        let retried = await asr.retryPendingGrokTranscription()
        XCTAssertEqual(retried, ASRService.applySpokenPunctuationFormatting("grok-retry"))
        XCTAssertEqual(local.transcribeFinalCount, 0)
        XCTAssertFalse(asr.debugGrokRetryStore.hasPending)
        XCTAssertFalse(asr.hasPendingSTTRetry)
    }

    func testLocalRecordingAfterGrokFailureClearsRetry() async {
        let session = GrokSTTFakeSession(
            configuration: .init(failBeforeAudioDone: .offline)
        )
        let grok = makeGrokSTTProvider(configured: true, session: session)
        grok.setRestFinalHandler { _, _ in throw GrokSTTError.offline }
        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = grok
        asr.testStreamingSessionFactory = { _ in session }
        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        asr.debugAppendPCM([Float](repeating: 0.1, count: 800))
        _ = await asr.stop()
        XCTAssertTrue(asr.hasPendingSTTRetry)

        let local = StubLocalTranscriptionProvider()
        asr.testTranscriptionProviderOverride = local
        asr.testStreamingSessionFactory = nil
        let localStart = await asr.start()
        XCTAssertEqual(localStart, .started)
        XCTAssertFalse(asr.hasPendingSTTRetry)
        XCTAssertFalse(asr.debugGrokRetryStore.hasPending)
        XCTAssertTrue(
            DictationOverlayStopPolicy.shouldHideOverlayOnStop(
                isNormalRoute: true,
                wasRewriteMode: false,
                wasCommandMode: false,
                isPromptTestActive: false,
                shouldUseAIOnStop: false,
                spokenSendEnabled: false,
                isCloudSessionActive: asr.isCloudSessionActive,
                hasPendingSTTRetry: asr.hasPendingSTTRetry
            )
        )

        asr.debugAppendPCM([Float](repeating: 0.5, count: 8_000))
        let text = await asr.stop()
        XCTAssertEqual(text, ASRService.applySpokenPunctuationFormatting("local"))
        XCTAssertGreaterThanOrEqual(local.transcribeFinalCount, 1)
    }

    func testResetTranscriptionProviderClearsRetry() async {
        let session = GrokSTTFakeSession(
            configuration: .init(failBeforeAudioDone: .offline)
        )
        let grok = makeGrokSTTProvider(configured: true, session: session)
        grok.setRestFinalHandler { _, _ in throw GrokSTTError.offline }
        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = grok
        asr.testStreamingSessionFactory = { _ in session }
        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        asr.debugAppendPCM([Float](repeating: 0.1, count: 400))
        _ = await asr.stop()
        XCTAssertTrue(asr.debugGrokRetryStore.hasPending)

        asr.resetTranscriptionProvider()
        XCTAssertFalse(asr.debugGrokRetryStore.hasPending)
        XCTAssertFalse(asr.hasPendingSTTRetry)
    }

    func testStopTimeTailIsEmittedAsHundredMillisecondFrames() async {
        let session = GrokSTTFakeSession(configuration: .init(transcriptOnFinish: "framed"))
        let provider = makeGrokSTTProvider(session: session)
        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = provider
        asr.testStreamingSessionFactory = { _ in session }

        session.setQueuedAudioFrameCount(21)
        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        _ = await waitUntil(timeout: 1) { asr.debugCreatedReceived }

        let pcm = [Float](repeating: 0.11, count: 4_000)
        asr.debugAppendPCM(pcm)
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(session.appendCallCount, 0, "pump must pause while queued > 20")

        session.setQueuedAudioFrameCount(0)
        let text = await asr.stop()
        XCTAssertEqual(text, ASRService.applySpokenPunctuationFormatting("framed"))
        // Pump sent nothing, so stop hands the entire utterance and finish()
        // still emits exact 100 ms / 1600-sample frames.
        XCTAssertEqual(session.handoffCallCount, 1)
        XCTAssertEqual(session.handoffPCM, pcm)
        XCTAssertEqual(session.appendedFrames.map(\.count), [3_200, 3_200, 1_600])
        XCTAssertEqual(session.appendedSampleCount, pcm.count)
    }

    func testCancelledSessionDoesNotPoisonNextRecording() async {
        let delayed = GrokSTTFakeSession(
            configuration: .init(createdDelay: 0.25, startError: .offline, transcriptOnFinish: "old")
        )
        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = makeGrokSTTProvider(session: delayed)
        asr.testStreamingSessionFactory = { _ in delayed }

        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        await asr.stopWithoutTranscription()

        let next = GrokSTTFakeSession(configuration: .init(transcriptOnFinish: "new"))
        asr.testTranscriptionProviderOverride = makeGrokSTTProvider(session: next)
        asr.testStreamingSessionFactory = { _ in next }
        let nextStart = await asr.start()
        XCTAssertEqual(nextStart, .started)
        asr.debugAppendPCM([Float](repeating: 0.1, count: 1_600))

        delayed.recordPartial(start: 0, text: "old-partial")
        try? await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertNil(asr.debugSessionTransportError)
        XCTAssertFalse(asr.partialTranscription.contains("old-partial"))

        let text = await asr.stop()
        XCTAssertEqual(text, ASRService.applySpokenPunctuationFormatting("new"))
        XCTAssertEqual(asr.lastStopOutcome, .success)
    }

    func testResetDuringStopDoesNotFallBackToLocalProvider() async {
        let session = GrokSTTFakeSession(
            configuration: .init(finishDelay: 0.35, failBeforeAudioDone: .timeout)
        )
        let grok = makeGrokSTTProvider(configured: true, session: session)
        let grokREST = TestCounter()
        grok.setRestFinalHandler { samples, _ in
            grokREST.increment()
            XCTAssertEqual(samples.count, 1_600)
            return ASRTranscriptionResult(text: "grok-rest", confidence: 1)
        }
        let local = StubLocalTranscriptionProvider()
        local.transcribeFinalText = "LOCAL"

        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = grok
        asr.testStreamingSessionFactory = { _ in session }
        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        asr.debugAppendPCM([Float](repeating: 0.1, count: 1_600))
        _ = await waitUntil(timeout: 1) { asr.debugCreatedReceived }

        let stopTask = Task { await asr.stop() }
        let enteredFinish = await waitUntil(timeout: 1) { session.finishCallCount > 0 }
        XCTAssertTrue(enteredFinish)
        XCTAssertTrue(asr.debugSessionOwnerLive)

        asr.testTranscriptionProviderOverride = local
        asr.testStreamingSessionFactory = nil
        asr.resetTranscriptionProvider()
        XCTAssertTrue(asr.debugIsSessionDictation)
        XCTAssertNotNil(asr.debugSessionGrokProvider)

        let text = await stopTask.value
        XCTAssertEqual(local.transcribeFinalCount, 0)
        XCTAssertEqual(grokREST.count, 1)
        XCTAssertEqual(text, ASRService.applySpokenPunctuationFormatting("grok-rest"))
        XCTAssertFalse(asr.debugSessionOwnerLive)
    }

    func testResetDuringFailedStopKeepsRetainedRetry() async {
        let session = GrokSTTFakeSession(
            configuration: .init(finishDelay: 0.35, failBeforeAudioDone: .timeout)
        )
        let grok = makeGrokSTTProvider(configured: true, session: session)
        grok.setRestFinalHandler { _, _ in throw GrokSTTError.offline }
        let local = StubLocalTranscriptionProvider()
        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = grok
        asr.testStreamingSessionFactory = { _ in session }
        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        asr.debugAppendPCM([Float](repeating: 0.1, count: 800))
        _ = await waitUntil(timeout: 1) { asr.debugCreatedReceived }

        let stopTask = Task { await asr.stop() }
        let enteredFinish = await waitUntil(timeout: 1) { session.finishCallCount > 0 }
        XCTAssertTrue(enteredFinish)
        asr.testTranscriptionProviderOverride = local
        asr.resetTranscriptionProvider()
        let text = await stopTask.value
        XCTAssertEqual(text, "")
        XCTAssertEqual(local.transcribeFinalCount, 0)
        XCTAssertTrue(asr.debugGrokRetryStore.hasPending)
        XCTAssertTrue(asr.hasPendingSTTRetry)
        XCTAssertFalse(
            DictationOverlayStopPolicy.shouldHideOverlayOnStop(
                isNormalRoute: true,
                wasRewriteMode: false,
                wasCommandMode: false,
                isPromptTestActive: false,
                shouldUseAIOnStop: false,
                spokenSendEnabled: false,
                isCloudSessionActive: asr.isCloudSessionActive,
                hasPendingSTTRetry: asr.hasPendingSTTRetry
            )
        )

        grok.setRestFinalHandler { samples, _ in
            XCTAssertEqual(samples.count, 800)
            return ASRTranscriptionResult(text: "grok-retry", confidence: 1)
        }
        let retried = await asr.retryPendingGrokTranscription()
        XCTAssertEqual(retried, ASRService.applySpokenPunctuationFormatting("grok-retry"))
        XCTAssertEqual(local.transcribeFinalCount, 0)
        XCTAssertFalse(asr.hasPendingSTTRetry)
    }

    func testSlowStopDoesNotCancelNewerStreamingSession() async {
        let park = TestLatch()
        let sessionA = GrokSTTFakeSession(
            configuration: .init(transcriptOnFinish: "from-a", finishPark: park)
        )
        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = makeGrokSTTProvider(session: sessionA)
        asr.testStreamingSessionFactory = { _ in sessionA }

        let startA = await asr.start()
        XCTAssertEqual(startA, .started)
        asr.debugAppendPCM([Float](repeating: 0.1, count: 1_600))
        _ = await waitUntil(timeout: 1) { asr.debugCreatedReceived }

        let stopA = Task { await asr.stop() }
        let enteredFinish = await waitUntil(timeout: 1) { sessionA.finishCallCount > 0 }
        XCTAssertTrue(enteredFinish)

        let sessionB = GrokSTTFakeSession(configuration: .init(transcriptOnFinish: "from-b"))
        asr.testTranscriptionProviderOverride = makeGrokSTTProvider(session: sessionB)
        asr.testStreamingSessionFactory = { _ in sessionB }
        let startB = await asr.start()
        XCTAssertEqual(startB, .started)
        XCTAssertTrue(asr.debugActiveStreamingSession === sessionB)
        XCTAssertTrue(asr.isRunning)

        park.resume()
        let textA = await stopA.value
        XCTAssertEqual(textA, ASRService.applySpokenPunctuationFormatting("from-a"))
        XCTAssertTrue(asr.debugActiveStreamingSession === sessionB)
        XCTAssertEqual(sessionB.cancelCallCount, 0)
        XCTAssertTrue(asr.isRunning)
        XCTAssertEqual(sessionB.finishCallCount, 0)

        asr.debugAppendPCM([Float](repeating: 0.2, count: 1_600))
        let textB = await asr.stop()
        XCTAssertEqual(textB, ASRService.applySpokenPunctuationFormatting("from-b"))
        XCTAssertEqual(sessionB.finishCallCount, 1)
        XCTAssertEqual(asr.lastStopOutcome, .success)
    }

    func testCreatedTransitionBetweenSnapshotAndHandoffSendsEntirePCM() async {
        let session = GrokSTTFakeSession(
            configuration: .init(
                createdDelay: 0.35,
                transcriptOnFinish: "caught-up",
                enterStreamingBeforeReturn: true
            )
        )
        let provider = makeGrokSTTProvider(configured: true, session: session)
        let restCalls = TestCounter()
        provider.setRestFinalHandler { _, _ in
            restCalls.increment()
            return ASRTranscriptionResult(text: "should-not-rest", confidence: 1)
        }
        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = provider
        asr.testStreamingSessionFactory = { _ in session }

        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        XCTAssertFalse(asr.debugCreatedReceived)
        let pcm = [Float](repeating: 0.12, count: 3_200)
        asr.debugAppendPCM(pcm)

        let streaming = await waitUntil(timeout: 1) { session.currentState == .streaming }
        XCTAssertTrue(streaming)
        XCTAssertFalse(asr.debugCreatedReceived)

        let text = await asr.stop()
        XCTAssertEqual(text, ASRService.applySpokenPunctuationFormatting("caught-up"))
        XCTAssertEqual(session.handoffCallCount, 1)
        XCTAssertEqual(session.handoffPCM, pcm)
        XCTAssertEqual(session.appendCallCount, 0)
        XCTAssertGreaterThanOrEqual(session.appendedSampleCount, pcm.count)
        XCTAssertEqual(restCalls.count, 0)
    }

    func testCancelClosesSessionWithoutWaitingForStart() async {
        let session = GrokSTTFakeSession(configuration: .init(startUntilCancelled: true))
        let provider = makeGrokSTTProvider(session: session)
        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = provider
        asr.testStreamingSessionFactory = { _ in session }

        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        asr.debugAppendPCM([Float](repeating: 0.2, count: 800))

        let startedAt = Date()
        await asr.stopWithoutTranscription()
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.75)
        XCTAssertEqual(session.cancelCallCount, 1)
        XCTAssertFalse(session.audioDoneSent)
        XCTAssertEqual(asr.debugAudioBufferCount, 0)
    }

    func testNeverCreatedFallsBackToFullPCMREST() async {
        let session = GrokSTTFakeSession(
            configuration: .init(neverCreated: true, createdTimeout: 0.05)
        )
        let provider = makeGrokSTTProvider(configured: true, session: session)
        let restCalls = TestCounter()
        let pcm = [Float](repeating: 0.18, count: 2_400)
        provider.setRestFinalHandler { samples, _ in
            restCalls.increment()
            XCTAssertEqual(samples, pcm)
            return ASRTranscriptionResult(text: "rest-from-timeout", confidence: 1)
        }
        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = provider
        asr.testStreamingSessionFactory = { _ in session }

        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        asr.debugAppendPCM(pcm)
        let text = await asr.stop()

        XCTAssertEqual(restCalls.count, 1)
        XCTAssertFalse(session.audioDoneSent)
        XCTAssertEqual(text, ASRService.applySpokenPunctuationFormatting("rest-from-timeout"))
        XCTAssertFalse(asr.hasPendingSTTRetry)
    }

    func testRetryUsesRetainedLanguageAndPublishesAudioSnapshot() async {
        let session = GrokSTTFakeSession(
            configuration: .init(failBeforeAudioDone: .offline)
        )
        let grok = makeGrokSTTProvider(configured: true, session: session)
        grok.setRestFinalHandler { _, _ in throw GrokSTTError.offline }

        let previousLanguage = SettingsStore.shared.selectedGrokSTTLanguageCode
        let previousHistory = SettingsStore.shared.saveTranscriptionHistory
        let previousAudio = SettingsStore.shared.saveAudioWithTranscriptionHistory
        SettingsStore.shared.selectedGrokSTTLanguageCode = "es"
        SettingsStore.shared.saveTranscriptionHistory = true
        SettingsStore.shared.saveAudioWithTranscriptionHistory = true
        defer {
            SettingsStore.shared.selectedGrokSTTLanguageCode = previousLanguage
            SettingsStore.shared.saveTranscriptionHistory = previousHistory
            SettingsStore.shared.saveAudioWithTranscriptionHistory = previousAudio
        }

        let asr = ASRService()
        asr.testBypassHardwareCapture = true
        asr.testTranscriptionProviderOverride = grok
        asr.testStreamingSessionFactory = { _ in session }
        let startOutcome = await asr.start()
        XCTAssertEqual(startOutcome, .started)
        let pcm = [Float](repeating: 0.22, count: 1_200)
        asr.debugAppendPCM(pcm)
        _ = await asr.stop()
        XCTAssertTrue(asr.hasPendingSTTRetry)
        XCTAssertEqual(asr.debugGrokRetryStore.pending?.languageCode, "es")

        SettingsStore.shared.selectedGrokSTTLanguageCode = "fr"
        var capturedLanguage: String?
        grok.setRestFinalHandler { samples, language in
            capturedLanguage = language
            XCTAssertEqual(samples, pcm)
            return ASRTranscriptionResult(text: "retried", confidence: 1)
        }

        let text = await asr.retryPendingGrokTranscription()
        XCTAssertEqual(text, ASRService.applySpokenPunctuationFormatting("retried"))
        XCTAssertEqual(capturedLanguage, "es")
        let snapshot = asr.consumeLastCompletedAudioSnapshot()
        XCTAssertEqual(snapshot?.samples, pcm)
        XCTAssertEqual(snapshot?.sampleRate, 16_000)
        XCTAssertEqual(snapshot?.channels, 1)
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval, predicate: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return predicate()
}
