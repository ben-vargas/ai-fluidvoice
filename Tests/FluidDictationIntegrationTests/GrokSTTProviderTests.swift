@testable import FluidVoice_Debug
import XCTest

@MainActor
final class GrokSTTProviderTests: XCTestCase {
    func testTranscriptionProviderAndGetProviderReturnGrokSTTProvider() {
        let asr = ASRService()
        XCTAssertTrue(asr.debugProvider(for: .grokSTT) is GrokSTTProvider)
        asr.testTranscriptionProviderOverride = GrokSTTProvider()
        XCTAssertTrue(asr.debugCachedTranscriptionProvider() is GrokSTTProvider)
        XCTAssertTrue(asr.debugCachedTranscriptionProvider() is StreamingTranscriptionProviding)
    }

    func testTranscribeStreamingThrows() async {
        let provider = makeGrokSTTProvider()
        do {
            _ = try await provider.transcribeStreaming([0.1, 0.2])
            XCTFail("transcribeStreaming must throw")
        } catch {
            XCTAssertNotNil(error as? GrokSTTError)
        }
    }

    func testDictionaryTrainingThrows() async {
        let provider = makeGrokSTTProvider()
        do {
            _ = try await provider.transcribeDictionaryTraining([0.1])
            XCTFail("dictionary training must throw")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .dictionaryTrainingUnsupported)
        }
    }

    func testModelsExistOnDiskIsFalseAndRESTStubsThrow() async {
        let provider = makeGrokSTTProvider()
        XCTAssertFalse(provider.modelsExistOnDisk())
        XCTAssertTrue(provider.shouldClearCacheAfterCancellation == false)
        do {
            _ = try await provider.transcribeFinal([0.1])
            XCTFail("REST stub must throw until PR3b")
        } catch {
            XCTAssertEqual((error as? GrokSTTError)?.numericCode, GrokSTTError.server(status: 501, message: "").numericCode)
        }
    }

    func testPrepareDoesNotSecondCallWhenModelsMissing() async throws {
        let provider = makeGrokSTTProvider()
        let calls = TestCounter()
        provider.setPrepareHandler { _ in
            calls.increment()
            throw GrokSTTError.offline
        }
        let asr = ASRService()
        asr.testTranscriptionProviderOverride = provider
        do {
            try await asr.ensureAsrReady()
            XCTFail("prepare should fail")
        } catch {
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(provider.prepareCallCount, 1)
        }
    }

    func testTranscriptionExecutorDoesNotHopMainActor() async throws {
        let provider = makeGrokSTTProvider()
        provider.setRestFinalHandler { samples, _ in
            XCTAssertFalse(Thread.isMainThread, "transcribeFinal must not hop to MainActor")
            XCTAssertEqual(samples.count, 1)
            return ASRTranscriptionResult(text: "ok", confidence: 1)
        }
        provider.setRestFileHandler { _ in
            XCTAssertFalse(Thread.isMainThread, "transcribeFile must not hop to MainActor")
            return ASRTranscriptionResult(text: "file", confidence: 1)
        }

        actor Executor {
            func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
                try await operation()
            }
        }

        let executor = Executor()
        let finished = expectation(description: "executor finished")
        Task { @MainActor in
            do {
                let final = try await executor.run {
                    try await provider.transcribeFinal([0.25])
                }
                XCTAssertEqual(final.text, "ok")
                let file = try await executor.run {
                    try await provider.transcribeFile(at: URL(fileURLWithPath: "/tmp/unused.wav"))
                }
                XCTAssertEqual(file.text, "file")
            } catch {
                XCTFail("executor deadlocked or threw: \(error)")
            }
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 2)
    }

    func testCloudEnsureAsrReadyDoesNotSetDownloading() async throws {
        let provider = makeGrokSTTProvider()
        let latch = TestLatch()
        let started = expectation(description: "prepare started")
        provider.setPrepareHandler { handler in
            handler?(.loading)
            started.fulfill()
            await latch.park()
        }
        let asr = ASRService()
        asr.testTranscriptionProviderOverride = provider
        let ready = Task { try await asr.ensureAsrReady() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(asr.isDownloadingModel)
        XCTAssertTrue(asr.isLoadingModel)
        XCTAssertEqual(asr.modelPreparationPhase, .loading)
        latch.resume()
        try await ready.value
        XCTAssertFalse(asr.modelsExistOnDisk)
        XCTAssertFalse(asr.isDownloadingModel)
    }
}
