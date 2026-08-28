@testable import FluidVoice_Debug
import XCTest

final class DictationOverlayStopPolicyTests: XCTestCase {
    func testDefaultDictationHidesOverlay() {
        XCTAssertTrue(
            DictationOverlayStopPolicy.shouldHideOverlayOnStop(
                isNormalRoute: true,
                wasRewriteMode: false,
                wasCommandMode: false,
                isPromptTestActive: false,
                shouldUseAIOnStop: false,
                spokenSendEnabled: false,
                isCloudSessionActive: false,
                hasPendingSTTRetry: false
            )
        )
    }

    func testCloudSessionOrPendingRetryKeepsOverlay() {
        XCTAssertFalse(
            DictationOverlayStopPolicy.shouldHideOverlayOnStop(
                isNormalRoute: true,
                wasRewriteMode: false,
                wasCommandMode: false,
                isPromptTestActive: false,
                shouldUseAIOnStop: false,
                spokenSendEnabled: false,
                isCloudSessionActive: true,
                hasPendingSTTRetry: false
            )
        )
        XCTAssertFalse(
            DictationOverlayStopPolicy.shouldHideOverlayOnStop(
                isNormalRoute: true,
                wasRewriteMode: false,
                wasCommandMode: false,
                isPromptTestActive: false,
                shouldUseAIOnStop: false,
                spokenSendEnabled: false,
                isCloudSessionActive: false,
                hasPendingSTTRetry: true
            )
        )
    }

    func testKeepLiveTranscriptOnlyForCloudSession() {
        XCTAssertTrue(
            DictationStopRoutingPolicy.shouldKeepLiveTranscriptOnStop(
                isCloudSessionActive: true,
                partialTranscription: "hello"
            )
        )
        XCTAssertFalse(
            DictationStopRoutingPolicy.shouldKeepLiveTranscriptOnStop(
                isCloudSessionActive: true,
                partialTranscription: "  "
            )
        )
        XCTAssertFalse(
            DictationStopRoutingPolicy.shouldKeepLiveTranscriptOnStop(
                isCloudSessionActive: false,
                partialTranscription: "hello"
            )
        )
    }

    func testSuccessfulStopIntentCoversAllRecordingRoutes() {
        XCTAssertEqual(
            DictationStopRoutingPolicy.intent(for: DictationStopRoutingContext(isPromptTestActive: true)),
            .promptTest
        )
        XCTAssertEqual(
            DictationStopRoutingPolicy.intent(for: DictationStopRoutingContext(wasRewriteMode: true)),
            .rewrite
        )
        XCTAssertEqual(
            DictationStopRoutingPolicy.intent(for: DictationStopRoutingContext(wasCommandMode: true)),
            .command
        )
        XCTAssertEqual(
            DictationStopRoutingPolicy.intent(for: DictationStopRoutingContext()),
            .dictation
        )
        XCTAssertEqual(
            DictationStopRoutingPolicy.intent(
                for: DictationStopRoutingContext(shouldUseAIOnStop: true)
            ),
            .dictation
        )
        XCTAssertEqual(
            DictationStopRoutingPolicy.intent(
                for: DictationStopRoutingContext(spokenSendEnabled: true)
            ),
            .dictation
        )
        XCTAssertEqual(
            DictationStopRoutingPolicy.intent(
                for: DictationStopRoutingContext(isNormalRoute: false, isOnboardingTryout: true)
            ),
            .dictation
        )
    }

    func testSuccessfulSTTRetryInvokesEveryRequiredDispatchRoute() async {
        let snapshot = DictationAudioSnapshot(
            samples: [0.1, 0.2, 0.3],
            sampleRate: 16_000,
            channels: 1
        )
        let routes: [(name: String, context: DictationStopRoutingContext, intent: DictationSuccessfulStopIntent)] = [
            ("normal", DictationStopRoutingContext(), .dictation),
            ("prompt-test", DictationStopRoutingContext(isPromptTestActive: true), .promptTest),
            ("ai-enhanced", DictationStopRoutingContext(shouldUseAIOnStop: true), .dictation),
            ("spoken-send", DictationStopRoutingContext(spokenSendEnabled: true), .dictation),
            ("rewrite", DictationStopRoutingContext(wasRewriteMode: true), .rewrite),
            ("command", DictationStopRoutingContext(wasCommandMode: true), .command),
        ]

        for route in routes {
            let probe = DictationSuccessfulStopProbe()
            let dispatch = DictationSuccessfulStopDispatch(
                transcribedText: "retried \(route.name)",
                audioSnapshot: snapshot,
                context: route.context,
                didRequestOverlayHideOnStop: false
            )
            XCTAssertEqual(dispatch.intent, route.intent, route.name)
            XCTAssertEqual(dispatch.audioSnapshot?.samples, snapshot.samples, route.name)
            XCTAssertEqual(dispatch.context.shouldUseAIOnStop, route.context.shouldUseAIOnStop, route.name)
            XCTAssertEqual(dispatch.context.spokenSendEnabled, route.context.spokenSendEnabled, route.name)

            await DictationSuccessfulStopDispatcher.invoke(
                dispatch,
                promptTest: { await probe.promptTest($0) },
                rewrite: { await probe.rewrite($0) },
                command: { await probe.command($0) },
                dictation: { await probe.dictation($0) }
            )

            switch route.intent {
            case .promptTest:
                XCTAssertEqual(probe.promptTestCalls, ["retried \(route.name)"], route.name)
                XCTAssertTrue(probe.rewriteCalls.isEmpty, route.name)
                XCTAssertTrue(probe.commandCalls.isEmpty, route.name)
                XCTAssertTrue(probe.dictationCalls.isEmpty, route.name)
            case .rewrite:
                XCTAssertEqual(probe.rewriteCalls, ["retried \(route.name)"], route.name)
                XCTAssertTrue(probe.promptTestCalls.isEmpty, route.name)
                XCTAssertTrue(probe.commandCalls.isEmpty, route.name)
                XCTAssertTrue(probe.dictationCalls.isEmpty, route.name)
            case .command:
                XCTAssertEqual(probe.commandCalls, ["retried \(route.name)"], route.name)
                XCTAssertTrue(probe.promptTestCalls.isEmpty, route.name)
                XCTAssertTrue(probe.rewriteCalls.isEmpty, route.name)
                XCTAssertTrue(probe.dictationCalls.isEmpty, route.name)
            case .dictation:
                XCTAssertEqual(probe.dictationCalls.count, 1, route.name)
                XCTAssertEqual(probe.dictationCalls.first?.transcribedText, "retried \(route.name)", route.name)
                XCTAssertEqual(probe.dictationCalls.first?.audioSnapshot?.samples, snapshot.samples, route.name)
                XCTAssertEqual(probe.dictationCalls.first?.context, route.context, route.name)
                XCTAssertTrue(probe.promptTestCalls.isEmpty, route.name)
                XCTAssertTrue(probe.rewriteCalls.isEmpty, route.name)
                XCTAssertTrue(probe.commandCalls.isEmpty, route.name)
            }
        }
    }
}

private final class DictationSuccessfulStopProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var promptTestStorage: [String] = []
    private var rewriteStorage: [String] = []
    private var commandStorage: [String] = []
    private var dictationStorage: [DictationSuccessfulStopDispatch] = []

    var promptTestCalls: [String] { self.lock.withLock { self.promptTestStorage } }
    var rewriteCalls: [String] { self.lock.withLock { self.rewriteStorage } }
    var commandCalls: [String] { self.lock.withLock { self.commandStorage } }
    var dictationCalls: [DictationSuccessfulStopDispatch] { self.lock.withLock { self.dictationStorage } }

    func promptTest(_ text: String) async {
        self.lock.withLock { self.promptTestStorage.append(text) }
    }

    func rewrite(_ text: String) async {
        self.lock.withLock { self.rewriteStorage.append(text) }
    }

    func command(_ text: String) async {
        self.lock.withLock { self.commandStorage.append(text) }
    }

    func dictation(_ dispatch: DictationSuccessfulStopDispatch) async {
        self.lock.withLock { self.dictationStorage.append(dispatch) }
    }
}
