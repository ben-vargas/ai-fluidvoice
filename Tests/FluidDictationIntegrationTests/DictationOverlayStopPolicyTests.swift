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
}
