@testable import FluidVoice_Debug
import XCTest

final class GrokSTTFakeSessionTests: XCTestCase {
    func testCancelDoesNotSendAudioDone() async throws {
        let session = GrokSTTFakeSession()
        try await session.start()
        session.append(pcm16: GrokSTTAudioConverter.pcm16LE(fromFloat32: [Float](repeating: 0.1, count: 1_600)))
        session.cancel()
        XCTAssertFalse(session.audioDoneSent)
        XCTAssertEqual(session.cancelCallCount, 1)
        XCTAssertEqual(session.currentState, .cancelled)
    }

    func testAppendBeforeCreatedIsNoOp() {
        let session = GrokSTTFakeSession()
        session.append(pcm16: Data(count: 4))
        XCTAssertEqual(session.appendCallCount, 1)
        XCTAssertEqual(session.appendedSampleCount, 0)
        XCTAssertEqual(session.currentState, .idle)
    }

    func testHandoffThenFinishSendsFromSampleZero() async throws {
        let session = GrokSTTFakeSession(configuration: .init(createdDelay: 0.05, transcriptOnFinish: "done"))
        session.handoffUnsentPCM([Float](repeating: 0.2, count: 3_200))
        let start = Task { try await session.start() }
        let text = try await session.finish()
        _ = try await start.value
        XCTAssertEqual(text, "done")
        XCTAssertTrue(session.audioDoneSent)
        XCTAssertEqual(session.handoffCallCount, 1)
        XCTAssertEqual(session.appendedSampleCount, 3_200)
    }
}
