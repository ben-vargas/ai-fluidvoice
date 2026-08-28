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

    func testModelsExistOnDiskIsFalse() {
        let provider = makeGrokSTTProvider()
        XCTAssertFalse(provider.modelsExistOnDisk())
        XCTAssertTrue(provider.shouldClearCacheAfterCancellation == false)
    }

    func testMakeStreamingSessionReturnsWebSocketSession() throws {
        let provider = GrokSTTProvider(resolver: StubGrokSTTResolver())
        let session = try provider.makeStreamingSession(configuration: .grokDictation)
        XCTAssertTrue(session is GrokSTTWebSocketSession)
        XCTAssertFalse(session is GrokSTTFakeSession)
    }

    func testTranscribeFinalUsesRESTClientOffMain() async throws {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 200, json: ["text": "rest-final"])
        let resolver = StubGrokSTTResolver()
        let provider = GrokSTTProvider(
            resolver: resolver,
            restClient: GrokSTTRESTClient(resolver: resolver, http: http)
        )
        let result = try await provider.transcribeFinal(
            [0.25, 0.5],
            languageCode: nil,
            keyterms: []
        )
        XCTAssertEqual(result.text, "rest-final")
        XCTAssertEqual(http.requests.count, 1)
    }

    func testGenericTranscribeAndTranscribeFinalUseREST() async throws {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 200, json: ["text": "pcm-chunk"])
        http.enqueue(status: 200, json: ["text": "pcm-final"])
        let resolver = StubGrokSTTResolver()
        let provider = GrokSTTProvider(
            resolver: resolver,
            restClient: GrokSTTRESTClient(resolver: resolver, http: http)
        )
        let chunk = try await provider.transcribe([0.25, 0.5])
        XCTAssertEqual(chunk.text, "pcm-chunk")
        let final = try await provider.transcribeFinal([0.25, 0.5])
        XCTAssertEqual(final.text, "pcm-final")
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(http.requests[0].timeoutInterval, GrokSTTRESTClient.meetingTimeout(durationSeconds: 2.0 / 16_000.0), accuracy: 0.01)
    }

    func testMeetingChunkEmptyTranscriptIsSkippedNotThrown() async throws {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 200, json: ["text": "hello there"])
        http.enqueue(status: 200, json: ["text": "   "])
        http.enqueue(status: 200, json: ["text": "world"])
        http.enqueue(status: 400, json: ["error": "invalid audio"])
        let resolver = StubGrokSTTResolver()
        let provider = GrokSTTProvider(
            resolver: resolver,
            restClient: GrokSTTRESTClient(resolver: resolver, http: http)
        )
        let samples = [Float](repeating: 0.1, count: 1_600)
        var texts: [String] = []
        for _ in 0..<4 {
            let result = try await provider.transcribe(samples)
            if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                texts.append(result.text)
            }
        }
        XCTAssertEqual(texts, ["hello there", "world"])
        XCTAssertEqual(http.requests.count, 4)
    }

    func testDictationTranscribeFinalStillThrowsEmptyTranscript() async {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 200, json: ["text": "  "])
        let resolver = StubGrokSTTResolver()
        let provider = GrokSTTProvider(
            resolver: resolver,
            restClient: GrokSTTRESTClient(resolver: resolver, http: http)
        )
        do {
            _ = try await provider.transcribeFinal([0.25], languageCode: nil, keyterms: [])
            XCTFail("dictation REST empty must throw")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .emptyTranscript)
        }
    }

    func testTranscribeFileUsesRESTClient() async throws {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 200, json: ["text": "meeting-file"])
        let resolver = StubGrokSTTResolver()
        let provider = GrokSTTProvider(
            resolver: resolver,
            restClient: GrokSTTRESTClient(resolver: resolver, http: http)
        )
        let fileURL = try Self.writeTempWAV(named: "standup.wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let result = try await provider.transcribeFile(at: fileURL)
        XCTAssertEqual(result.text, "meeting-file")
        XCTAssertEqual(http.requests.count, 1)
        let body = String(decoding: http.requests[0].httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("filename=\"standup.wav\""))
        XCTAssertFalse(body.contains("audio_format"))
        XCTAssertFalse(body.contains("diarize"))
    }

    func testTranscribeFileEmptyTranscriptReturnsEmptyResult() async throws {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 200, json: ["text": "  "])
        let resolver = StubGrokSTTResolver()
        let provider = GrokSTTProvider(
            resolver: resolver,
            restClient: GrokSTTRESTClient(resolver: resolver, http: http)
        )
        let fileURL = try Self.writeTempWAV(named: "silent-meeting.wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let result = try await provider.transcribeFile(at: fileURL)
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.confidence, 0)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testWireLanguageCodeOmitsAutoAndMapsTl() {
        XCTAssertNil(GrokSTTProvider.wireLanguageCode(nil))
        XCTAssertNil(GrokSTTProvider.wireLanguageCode("auto"))
        XCTAssertEqual(GrokSTTProvider.wireLanguageCode("fil"), "fil")
        XCTAssertEqual(GrokSTTProvider.wireLanguageCode("tl"), "fil")
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
                    try await provider.transcribeFinal([0.25], languageCode: nil, keyterms: nil)
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

    func testEnsureAsrReadyResolvesCredentialOffMain() async throws {
        // ensureAsrReady creates its readiness task on MainActor; the provider's
        // credential I/O must hop off that executor internally.
        let resolver = ThreadRecordingGrokSTTResolver()
        let provider = GrokSTTProvider(resolver: resolver)
        let asr = ASRService()
        asr.testTranscriptionProviderOverride = provider
        try await asr.ensureAsrReady()
        XCTAssertEqual(resolver.resolveCallCount, 1)
        XCTAssertEqual(resolver.sawMainThread, false)
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

private final class ThreadRecordingGrokSTTResolver: GrokSTTCredentialResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var sawMainThreadStorage: Bool?
    private var resolveCallCountStorage = 0

    var isSourceConfigured: Bool { true }

    var sawMainThread: Bool? {
        self.lock.withLock { self.sawMainThreadStorage }
    }

    var resolveCallCount: Int {
        self.lock.withLock { self.resolveCallCountStorage }
    }

    func resolveCredential() async throws -> GrokSTTCredential {
        self.lock.withLock {
            self.resolveCallCountStorage += 1
            self.sawMainThreadStorage = Thread.isMainThread
        }
        return GrokSTTCredential(
            bearer: "xai-stt-test-key",
            source: .apiKey,
            expiresAt: nil,
            accountLabel: "test"
        )
    }

    func resolveCredentialAfterUnauthorized(rejectedBearerFingerprint: String) async throws -> GrokSTTCredential {
        _ = rejectedBearerFingerprint
        throw GrokSTTError.unauthorized
    }
}

extension GrokSTTProviderTests {
    fileprivate static func writeTempWAV(named name: String) throws -> URL {
        let samples = [Float](repeating: 0.1, count: 1_600)
        let wav = GrokSTTAudioConverter.wav(fromFloat32: samples)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try wav.write(to: url)
        return url
    }
}
