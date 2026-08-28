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
}
