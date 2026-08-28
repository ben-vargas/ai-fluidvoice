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
        provider.setRestFinalHandler { _ in
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
        provider.setRestFinalHandler { samples in
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
        provider.setRestFinalHandler { _ in
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
