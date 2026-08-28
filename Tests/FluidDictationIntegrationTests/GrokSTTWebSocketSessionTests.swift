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
            transport: transport
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
            transport: transport
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
            transport: transport
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
            transport: transport
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
            transport: transport
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
            transport: transport
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
            transport: transport
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
            transport: transport
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
            transport: transport
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
}
