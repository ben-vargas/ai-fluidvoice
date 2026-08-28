@testable import FluidVoice_Debug
import XCTest

final class GrokSTTFakeSessionTests: XCTestCase {
    @MainActor
    func testStartAndFinishRunOffMainActorWhenCalledFromMainActor() async throws {
        let session = GrokSTTFakeSession(configuration: .init(transcriptOnFinish: "off-main"))
        try await session.start()
        session.handoffUnsentPCM([Float](repeating: 0.1, count: 1_600))
        let text = try await session.finish()
        XCTAssertEqual(text, "off-main")
    }

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

    func testHandoffIsLegalInStreamingWhenNoFramesWereAppended() async throws {
        let session = GrokSTTFakeSession(configuration: .init(transcriptOnFinish: "handoff"))
        try await session.start()
        XCTAssertEqual(session.currentState, .streaming)
        let pcm = [Float](repeating: 0.3, count: 1_600)
        session.handoffUnsentPCM(pcm)
        XCTAssertEqual(session.handoffCallCount, 1)
        XCTAssertEqual(session.handoffPCM, pcm)

        let text = try await session.finish()
        XCTAssertEqual(text, "handoff")
        XCTAssertEqual(session.appendedSampleCount, pcm.count)
        XCTAssertTrue(session.audioDoneSent)
    }

    func testStartExitsOnlyWhenCancelIsInvoked() async {
        let finished = TestCounter()
        let session = GrokSTTFakeSession(configuration: .init(startUntilCancelled: true))
        let start = Task {
            defer { finished.increment() }
            do {
                try await session.start()
                return "returned"
            } catch {
                return "threw"
            }
        }
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(session.cancelCallCount, 0)
        start.cancel()
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(finished.count, 0, "start() must ignore Task cancellation and wait for cancel()")
        session.cancel()
        let outcome = await start.value
        XCTAssertEqual(outcome, "threw")
        XCTAssertEqual(session.cancelCallCount, 1)
        XCTAssertEqual(finished.count, 1)
        XCTAssertFalse(session.audioDoneSent)
    }
}
