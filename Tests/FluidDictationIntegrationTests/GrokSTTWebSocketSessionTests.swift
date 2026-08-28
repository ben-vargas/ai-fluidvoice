@testable import FluidVoice_Debug
import XCTest

final class GrokSTTWebSocketSessionTests: XCTestCase {
    func testURLOmitsLanguageWhenAutoAndRepeatsKeyterms() {
        let url = GrokSTTWebSocketSession.makeURL(
            configuration: StreamingSTTSessionConfiguration(
                sampleRate: 16_000,
                languageCode: nil,
                keyterms: ["FluidVoice", "Grok"],
                interimResults: true
            )
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.filter { $0.name == "sample_rate" }.map(\.value), ["16000"])
        XCTAssertEqual(items.filter { $0.name == "encoding" }.map(\.value), ["pcm"])
        XCTAssertEqual(items.filter { $0.name == "interim_results" }.map(\.value), ["true"])
        XCTAssertTrue(items.filter { $0.name == "language" }.isEmpty)
        XCTAssertEqual(items.filter { $0.name == "keyterm" }.compactMap(\.value), ["FluidVoice", "Grok"])
        XCTAssertFalse(url.absoluteString.contains("endpointing"))
        XCTAssertFalse(url.absoluteString.contains("smart_turn"))
        XCTAssertFalse(url.absoluteString.contains("diarize"))
    }

    func testURLMapsFilAndDoesNotSendTl() {
        let url = GrokSTTWebSocketSession.makeURL(
            configuration: .init(sampleRate: 16_000, languageCode: "fil", keyterms: [], interimResults: true)
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "language" }?.value, "fil")
        XCTAssertFalse(url.absoluteString.contains("tl="))
    }

    func testStartWaitsForCreatedBeforeAppend() async throws {
        let transport = FakeGrokSTTWebSocketTransport()
        let connection = FakeGrokSTTWebSocketConnection()
        transport.enqueueConnection(connection)
        let session = GrokSTTWebSocketSession(
            configuration: .grokDictation,
            resolver: RecordingGrokSTTResolver(),
            transport: transport,
            apiKeySocketEnabled: true
        )

        let start = Task.detached { try await session.start() }
        await grokSTTAssertEventually { transport.connections.count == 1 }
        session.append(pcm16: Data(count: 32))
        XCTAssertEqual(session.debugAppendedFrameCount, 0)
        XCTAssertEqual(connection.sentBinary.count, 0)

        connection.emitJSON(["type": "transcript.created"])
        try await start.value
        XCTAssertEqual(session.currentState, .streaming)

        session.append(pcm16: Data(count: GrokSTTAudioConverter.bytesPerFrame))
        await grokSTTAssertEventually { connection.sentBinary.count == 1 }
        XCTAssertEqual(connection.sentBinary.first?.count, GrokSTTAudioConverter.bytesPerFrame)
        XCTAssertTrue(connection.sentText.isEmpty)
    }

    func testCancelDoesNotSendAudioDone() async throws {
        let transport = FakeGrokSTTWebSocketTransport()
        let connection = FakeGrokSTTWebSocketConnection()
        transport.enqueueConnection(connection)
        let session = GrokSTTWebSocketSession(
            configuration: .grokDictation,
            resolver: RecordingGrokSTTResolver(),
            transport: transport,
            apiKeySocketEnabled: true
        )
        let start = Task.detached { try await session.start() }
        await grokSTTAssertEventually { transport.connections.count == 1 }
        connection.emitJSON(["type": "transcript.created"])
        try await start.value
        session.append(pcm16: Data(count: 8))
        session.cancel()
        XCTAssertFalse(session.debugAudioDoneSent)
        XCTAssertTrue(connection.closed)
        XCTAssertFalse(connection.sentText.contains { $0.contains("audio.done") })
    }

    func testEmptyDoneKeepsPartialsAndFinishSucceeds() async throws {
        let transport = FakeGrokSTTWebSocketTransport()
        let connection = FakeGrokSTTWebSocketConnection()
        transport.enqueueConnection(connection)
        let session = GrokSTTWebSocketSession(
            configuration: .grokDictation,
            resolver: RecordingGrokSTTResolver(),
            transport: transport,
            apiKeySocketEnabled: true
        )
        let start = Task.detached { try await session.start() }
        await grokSTTAssertEventually { transport.connections.count == 1 }
        connection.emitJSON(["type": "transcript.created"])
        try await start.value
        connection.emitJSON(["type": "transcript.partial", "start": 0, "text": "hello there"])

        let finish = Task.detached { try await session.finish() }
        await grokSTTAssertEventually { connection.sentText.contains { $0.contains("audio.done") } }
        connection.emitJSON(["type": "transcript.done", "text": "", "duration": 1.1])
        let text = try await finish.value
        XCTAssertEqual(text, "hello there")
        XCTAssertTrue(session.debugAudioDoneSent)
    }

    func testPreAudioDoneDropDoesNotReturnPartials() async throws {
        let transport = FakeGrokSTTWebSocketTransport()
        let connection = FakeGrokSTTWebSocketConnection()
        transport.enqueueConnection(connection)
        let session = GrokSTTWebSocketSession(
            configuration: .grokDictation,
            resolver: RecordingGrokSTTResolver(),
            transport: transport,
            apiKeySocketEnabled: true
        )
        let start = Task.detached { try await session.start() }
        await grokSTTAssertEventually { transport.connections.count == 1 }
        connection.emitJSON(["type": "transcript.created"])
        try await start.value
        connection.emitJSON(["type": "transcript.partial", "start": 0, "text": "partial-must-not-insert"])
        connection.emitError(GrokSTTError.socketClosed(code: 1006))
        await grokSTTAssertEventually { session.transportError != nil }

        do {
            _ = try await Task.detached { try await session.finish() }.value
            XCTFail("pre-audio.done drop must throw")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .socketClosed(code: 1006))
        }
        XCTAssertEqual(session.transcript, "partial-must-not-insert")
        XCTAssertFalse(session.debugAudioDoneSent)
        XCTAssertNotNil(session.transportError)
    }

    func testPostDoneTransportErrorWithTextSucceeds() async throws {
        let transport = FakeGrokSTTWebSocketTransport()
        let connection = FakeGrokSTTWebSocketConnection()
        transport.enqueueConnection(connection)
        let session = GrokSTTWebSocketSession(
            configuration: .grokDictation,
            resolver: RecordingGrokSTTResolver(),
            transport: transport,
            apiKeySocketEnabled: true
        )
        let start = Task.detached { try await session.start() }
        await grokSTTAssertEventually { transport.connections.count == 1 }
        connection.emitJSON(["type": "transcript.created"])
        try await start.value
        connection.emitJSON(["type": "transcript.partial", "start": 0, "text": "kept"])

        let finish = Task.detached { try await session.finish() }
        await grokSTTAssertEventually { session.debugAudioDoneSent }
        connection.emitError(GrokSTTError.socketClosed(code: 1006))
        let text = try await finish.value
        XCTAssertEqual(text, "kept")
    }

    func testHandoffThenFinishSendsFromSampleZero() async throws {
        let transport = FakeGrokSTTWebSocketTransport()
        let connection = FakeGrokSTTWebSocketConnection()
        transport.enqueueConnection(connection)
        let session = GrokSTTWebSocketSession(
            configuration: .grokDictation,
            resolver: RecordingGrokSTTResolver(),
            transport: transport,
            apiKeySocketEnabled: true
        )
        let pcm = [Float](repeating: 0.25, count: 3_200)
        session.handoffUnsentPCM(pcm)
        let start = Task.detached { try await session.start() }
        let finish = Task.detached { try await session.finish() }
        await grokSTTAssertEventually { transport.connections.count == 1 }
        connection.emitJSON(["type": "transcript.created"])
        await grokSTTAssertEventually { connection.sentBinary.count >= 2 }
        connection.emitJSON(["type": "transcript.done", "text": "from-handoff"])
        let text = try await finish.value
        _ = try await start.value
        XCTAssertEqual(text, "from-handoff")
        XCTAssertEqual(connection.sentBinary.reduce(0) { $0 + $1.count }, 3_200 * 2)
        XCTAssertTrue(session.debugAudioDoneSent)
    }

    func testCLIUnauthorizedReconnectsOnce() async throws {
        let transport = FakeGrokSTTWebSocketTransport()
        transport.enqueueConnectFailure(GrokSTTError.unauthorized)
        let second = FakeGrokSTTWebSocketConnection()
        transport.enqueueConnection(second)
        let resolver = RecordingGrokSTTResolver(
            source: .grokCLISession,
            bearer: "cli-first",
            alternateBearer: "cli-second"
        )
        let session = GrokSTTWebSocketSession(
            configuration: .grokDictation,
            resolver: resolver,
            transport: transport,
            apiKeySocketEnabled: true
        )
        let start = Task.detached { try await session.start() }
        await grokSTTAssertEventually { transport.requests.count == 2 }
        second.emitJSON(["type": "transcript.created"])
        try await start.value
        XCTAssertEqual(resolver.unauthorizedCallCount, 1)
        XCTAssertEqual(session.currentState, .streaming)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertTrue(transport.requests.allSatisfy { request in
            (request.value(forHTTPHeaderField: "Authorization") ?? "").hasPrefix("Bearer ")
        })
    }

    func testAPIKeyUnauthorizedDoesNotReconnect() async {
        let transport = FakeGrokSTTWebSocketTransport()
        transport.enqueueConnectFailure(GrokSTTError.unauthorized)
        let resolver = RecordingGrokSTTResolver(source: .apiKey, alternateBearer: "should-not-use")
        let session = GrokSTTWebSocketSession(
            configuration: .grokDictation,
            resolver: resolver,
            transport: transport,
            apiKeySocketEnabled: true
        )
        do {
            try await Task.detached { try await session.start() }.value
            XCTFail("API key 401 must not reconnect")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .unauthorized)
        }
        XCTAssertEqual(resolver.unauthorizedCallCount, 0)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testCLISocketDisabledThrowsWithoutConnecting() async {
        let transport = FakeGrokSTTWebSocketTransport()
        let session = GrokSTTWebSocketSession(
            configuration: .grokDictation,
            resolver: RecordingGrokSTTResolver(source: .grokCLISession),
            transport: transport,
            cliSocketEnabled: false
        )
        do {
            try await Task.detached { try await session.start() }.value
            XCTFail("CLI socket disabled must throw")
        } catch {
            XCTAssertEqual((error as? GrokSTTError)?.numericCode, 1500)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAuthorizationHeaderIsBearerAndRequestDoesNotLogToken() {
        let credential = GrokSTTCredential(
            bearer: "super-secret-token-value",
            source: .apiKey,
            expiresAt: nil,
            accountLabel: nil
        )
        let request = GrokSTTWebSocketSession.makeRequest(
            configuration: .grokDictation,
            credential: credential
        )
        let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
        XCTAssertTrue(header.hasPrefix("Bearer "))
        XCTAssertGreaterThan(header.count, 8)
        XCTAssertEqual(request.timeoutInterval, 20)
    }

    func testStartAndFinishRunOffMainActor() async throws {
        let transport = FakeGrokSTTWebSocketTransport()
        let connection = FakeGrokSTTWebSocketConnection()
        transport.enqueueConnection(connection)
        let session = GrokSTTWebSocketSession(
            configuration: .grokDictation,
            resolver: RecordingGrokSTTResolver(),
            transport: transport,
            apiKeySocketEnabled: true
        )
        try await Task.detached {
            let start = Task { try await session.start() }
            while transport.connections.isEmpty {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            connection.emitJSON(["type": "transcript.created"])
            try await start.value
            connection.emitJSON(["type": "transcript.partial", "start": 0, "text": "off-main"])
            let finish = Task { try await session.finish() }
            while !session.debugAudioDoneSent {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            connection.emitJSON(["type": "transcript.done", "text": "off-main"])
            let text = try await finish.value
            XCTAssertEqual(text, "off-main")
        }.value
    }

    func testFinishAfterCreatedBudgetStillSendsAudioDone() async throws {
        let transport = FakeGrokSTTWebSocketTransport()
        let connection = FakeGrokSTTWebSocketConnection()
        transport.enqueueConnection(connection)
        let session = GrokSTTWebSocketSession(
            configuration: .grokDictation,
            resolver: RecordingGrokSTTResolver(),
            transport: transport,
            apiKeySocketEnabled: true
        )
        let start = Task.detached { try await session.start() }
        await grokSTTAssertEventually { transport.connections.count == 1 }
        connection.emitJSON(["type": "transcript.created"])
        try await start.value
        connection.emitJSON(["type": "transcript.partial", "start": 0, "text": "long-hold"])
        session.debugBackdateConnectStart(by: GrokSTTWebSocketSession.createdBudget + 5)

        let finish = Task.detached { try await session.finish() }
        await grokSTTAssertEventually { connection.sentText.contains { $0.contains("audio.done") } }
        connection.emitJSON(["type": "transcript.done", "text": "long-hold"])
        let text = try await finish.value
        XCTAssertEqual(text, "long-hold")
        XCTAssertTrue(session.debugAudioDoneSent)
        XCTAssertNotEqual(session.currentState, .failed)
    }

    func testDropDuringAudioDoneSendIsPreDone() async throws {
        let transport = FakeGrokSTTWebSocketTransport()
        let connection = FakeGrokSTTWebSocketConnection()
        transport.enqueueConnection(connection)
        let sendStarted = TestGate()
        let sendHold = TestGate()
        connection.setSendTextHook {
            sendStarted.signal()
            await sendHold.wait()
        }
        let session = GrokSTTWebSocketSession(
            configuration: .grokDictation,
            resolver: RecordingGrokSTTResolver(),
            transport: transport,
            apiKeySocketEnabled: true
        )
        let start = Task.detached { try await session.start() }
        await grokSTTAssertEventually { transport.connections.count == 1 }
        connection.emitJSON(["type": "transcript.created"])
        try await start.value
        connection.emitJSON(["type": "transcript.partial", "start": 0, "text": "must-not-insert"])

        let finish = Task.detached { try await session.finish() }
        await sendStarted.wait()
        XCTAssertFalse(session.debugAudioDoneSent)
        connection.emitError(GrokSTTError.socketClosed(code: 1006))
        await grokSTTAssertEventually { session.transportError != nil }
        sendHold.signal()

        do {
            _ = try await finish.value
            XCTFail("drop before audio.done send must throw")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .socketClosed(code: 1006))
        }
        XCTAssertFalse(session.debugAudioDoneSent)
        XCTAssertEqual(session.transcript, "must-not-insert")
    }

    func testSerializedSenderSendsFramesBeforeAudioDone() async throws {
        let transport = FakeGrokSTTWebSocketTransport()
        let connection = FakeGrokSTTWebSocketConnection()
        transport.enqueueConnection(connection)
        let firstStarted = TestGate()
        let firstHold = TestGate()
        let sendCount = TestCounter()
        connection.setSendDataHook {
            let n = sendCount.incrementAndGet()
            if n == 1 {
                firstStarted.signal()
                await firstHold.wait()
            }
        }
        let session = GrokSTTWebSocketSession(
            configuration: .grokDictation,
            resolver: RecordingGrokSTTResolver(),
            transport: transport,
            apiKeySocketEnabled: true
        )
        let start = Task.detached { try await session.start() }
        await grokSTTAssertEventually { transport.connections.count == 1 }
        connection.emitJSON(["type": "transcript.created"])
        try await start.value

        let frameA = Data(repeating: 1, count: 8)
        let frameB = Data(repeating: 2, count: 8)
        session.append(pcm16: frameA)
        await firstStarted.wait()
        session.append(pcm16: frameB)
        connection.emitJSON(["type": "transcript.partial", "start": 0, "text": "ordered"])

        let finish = Task.detached { try await session.finish() }
        await grokSTTAssertEventually { session.queuedAudioFrameCount >= 1 }
        firstHold.signal()
        await grokSTTAssertEventually { connection.sentText.contains { $0.contains("audio.done") } }
        connection.emitJSON(["type": "transcript.done", "text": "ordered"])
        let text = try await finish.value
        XCTAssertEqual(text, "ordered")
        XCTAssertEqual(connection.sentBinary, [frameA, frameB])
        XCTAssertEqual(connection.sentText.filter { $0.contains("audio.done") }.count, 1)
        XCTAssertTrue(session.debugAudioDoneSent)
    }

    func testEmptyDoneTimeoutClosesAndThrows() async throws {
        let transport = FakeGrokSTTWebSocketTransport()
        let connection = FakeGrokSTTWebSocketConnection()
        transport.enqueueConnection(connection)
        let session = GrokSTTWebSocketSession(
            configuration: .grokDictation,
            resolver: RecordingGrokSTTResolver(),
            transport: transport,
            apiKeySocketEnabled: true,
            doneTimeout: 0.15
        )
        let start = Task.detached { try await session.start() }
        await grokSTTAssertEventually { transport.connections.count == 1 }
        connection.emitJSON(["type": "transcript.created"])
        try await start.value

        do {
            _ = try await Task.detached { try await session.finish() }.value
            XCTFail("empty done-timeout must throw")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .timeout)
        }
        XCTAssertTrue(connection.closed)
        XCTAssertTrue(session.debugAudioDoneSent)
        XCTAssertEqual(session.currentState, .failed)
    }

    func testWebSocketSessionConfigurationDoesNotCapResourceToConnectTimeout() {
        let configuration = GrokSTTURLSessionWebSocketConnection.makeSessionConfiguration()
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertEqual(
            configuration.timeoutIntervalForRequest,
            GrokSTTURLSessionWebSocketTransport.connectTimeout
        )
        XCTAssertNotEqual(
            configuration.timeoutIntervalForResource,
            GrokSTTURLSessionWebSocketTransport.connectTimeout
        )
        XCTAssertTrue(
            configuration.timeoutIntervalForResource == 0
                || configuration.timeoutIntervalForResource > 10 * 60,
            "resource timeout must not cap a long dictation hold"
        )
    }

    func testDelayedResolverHangingConnectTimesOutWithinCreatedBudget() async {
        let transport = FakeGrokSTTWebSocketTransport()
        transport.hangNextConnect()
        let resolver = RecordingGrokSTTResolver()
        resolver.resolveDelayNanoseconds = 150_000_000
        let session = GrokSTTWebSocketSession(
            configuration: .grokDictation,
            resolver: resolver,
            transport: transport,
            apiKeySocketEnabled: true,
            createdBudget: 0.6
        )
        let started = Date()
        do {
            try await Task.detached { try await session.start() }.value
            XCTFail("delayed resolver plus hanging connect must timeout")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .timeout)
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 2, "created budget must bound handshake, not add a fresh 20s connect")
        XCTAssertGreaterThanOrEqual(elapsed, 0.45)
        XCTAssertTrue(transport.connectWasCancelled)
        XCTAssertEqual(transport.requests.count, 1)
        let handshakeTimeout = transport.requests.first?.timeoutInterval ?? -1
        XCTAssertGreaterThan(handshakeTimeout, 0)
        XCTAssertLessThan(handshakeTimeout, 0.6)
    }

    func testCancelDuringConnectAbortsPendingOpen() async {
        let transport = FakeGrokSTTWebSocketTransport()
        transport.hangNextConnect()
        let session = GrokSTTWebSocketSession(
            configuration: .grokDictation,
            resolver: RecordingGrokSTTResolver(),
            transport: transport,
            apiKeySocketEnabled: true
        )
        let start = Task.detached { try await session.start() }
        await transport.connectStarted.wait()
        start.cancel()
        session.cancel()
        do {
            try await start.value
            XCTFail("cancel during connect must not hang")
        } catch {
            let grok = error as? GrokSTTError
            XCTAssertTrue(
                grok == .cancelled || error is CancellationError,
                "expected cancelled, got \(error)"
            )
        }
        XCTAssertTrue(transport.connectWasCancelled)
        XCTAssertEqual(session.currentState, .cancelled)
    }

    func testFailedOpenCleansUpOnUnauthorized() async throws {
        let server = try LoopbackHTTPStatusServer(statusCode: 401)
        defer { server.stop() }
        let transport = GrokSTTURLSessionWebSocketTransport()
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(server.port)/v1/stt")!)
        request.setValue("Bearer xai-bad-key", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3
        do {
            _ = try await transport.connect(request: request)
            XCTFail("401 upgrade must fail")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .unauthorized)
        }
        XCTAssertEqual(transport.debugLastConnection?.debugIsClosed, true)
        XCTAssertEqual(transport.debugLastConnection?.debugRetainsURLSession, false)
    }

    func testFailedOpenCleansUpOnOffline() async {
        let transport = GrokSTTURLSessionWebSocketTransport()
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:1/v1/stt")!)
        request.setValue("Bearer xai-test-key", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 2
        do {
            _ = try await transport.connect(request: request)
            XCTFail("offline upgrade must fail")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .offline)
        }
        XCTAssertEqual(transport.debugLastConnection?.debugIsClosed, true)
        XCTAssertEqual(transport.debugLastConnection?.debugRetainsURLSession, false)
    }

    func testPartialDoneTimeoutSucceedsAndCloses() async throws {
        let transport = FakeGrokSTTWebSocketTransport()
        let connection = FakeGrokSTTWebSocketConnection()
        transport.enqueueConnection(connection)
        let session = GrokSTTWebSocketSession(
            configuration: .grokDictation,
            resolver: RecordingGrokSTTResolver(),
            transport: transport,
            apiKeySocketEnabled: true,
            doneTimeout: 0.15
        )
        let start = Task.detached { try await session.start() }
        await grokSTTAssertEventually { transport.connections.count == 1 }
        connection.emitJSON(["type": "transcript.created"])
        try await start.value
        connection.emitJSON(["type": "transcript.partial", "start": 0, "text": "kept-on-timeout"])

        let text = try await Task.detached { try await session.finish() }.value
        XCTAssertEqual(text, "kept-on-timeout")
        XCTAssertTrue(connection.closed)
        XCTAssertTrue(session.debugAudioDoneSent)
        XCTAssertEqual(session.currentState, .complete)
    }
}
