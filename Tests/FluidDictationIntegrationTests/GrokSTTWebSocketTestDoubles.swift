@testable import FluidVoice_Debug
import Foundation
import XCTest

final class FakeGrokSTTWebSocketConnection: GrokSTTWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var incoming: [Result<GrokSTTWebSocketMessage, Error>] = []
    private var waiters: [CheckedContinuation<GrokSTTWebSocketMessage, Error>] = []
    private var sendDataHook: (@Sendable () async -> Void)?
    private var sendTextHook: (@Sendable () async -> Void)?
    private(set) var sentBinary: [Data] = []
    private(set) var sentText: [String] = []
    private(set) var closed = false

    func setSendDataHook(_ hook: (@Sendable () async -> Void)?) {
        self.lock.withLock { self.sendDataHook = hook }
    }

    func setSendTextHook(_ hook: (@Sendable () async -> Void)?) {
        self.lock.withLock { self.sendTextHook = hook }
    }

    func send(data: Data) async throws {
        let hook = self.lock.withLock { self.sendDataHook }
        if let hook { await hook() }
        try self.lock.withLock { () -> Void in
            if self.closed { throw GrokSTTError.cancelled }
            self.sentBinary.append(data)
        }
    }

    func send(text: String) async throws {
        let hook = self.lock.withLock { self.sendTextHook }
        if let hook { await hook() }
        try self.lock.withLock { () -> Void in
            if self.closed { throw GrokSTTError.cancelled }
            self.sentText.append(text)
        }
    }

    func receive() async throws -> GrokSTTWebSocketMessage {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            if let next = self.incoming.first {
                self.incoming.removeFirst()
                self.lock.unlock()
                continuation.resume(with: next)
                return
            }
            self.waiters.append(continuation)
            self.lock.unlock()
        }
    }

    func close() {
        self.lock.lock()
        self.closed = true
        let waiters = self.waiters
        self.waiters = []
        self.lock.unlock()
        waiters.forEach { $0.resume(throwing: GrokSTTError.cancelled) }
    }

    func emitJSON(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        let text = String(data: data, encoding: .utf8)!
        self.emit(.success(.text(text)))
    }

    func emitError(_ error: Error) {
        self.emit(.failure(error))
    }

    private func emit(_ result: Result<GrokSTTWebSocketMessage, Error>) {
        self.lock.lock()
        if let waiter = self.waiters.first {
            self.waiters.removeFirst()
            self.lock.unlock()
            waiter.resume(with: result)
            return
        }
        self.incoming.append(result)
        self.lock.unlock()
    }
}

final class FakeGrokSTTWebSocketTransport: GrokSTTWebSocketTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var connectResults: [Result<FakeGrokSTTWebSocketConnection, Error>] = []
    private var hangConnect = false
    private var hangingContinuations: [CheckedContinuation<FakeGrokSTTWebSocketConnection, Error>] = []
    private(set) var requests: [URLRequest] = []
    private(set) var connections: [FakeGrokSTTWebSocketConnection] = []
    private(set) var connectWasCancelled = false
    let connectStarted = TestGate()

    func enqueueConnection(_ connection: FakeGrokSTTWebSocketConnection) {
        self.lock.withLock { self.connectResults.append(.success(connection)) }
    }

    func enqueueConnectFailure(_ error: Error) {
        self.lock.withLock { self.connectResults.append(.failure(error)) }
    }

    func hangNextConnect() {
        self.lock.withLock { self.hangConnect = true }
    }

    func connect(request: URLRequest) async throws -> any GrokSTTWebSocketConnection {
        let shouldHang = self.lock.withLock { () -> Bool in
            self.requests.append(request)
            return self.hangConnect
        }
        if shouldHang {
            return try await self.awaitHangingConnect()
        }
        let result: Result<FakeGrokSTTWebSocketConnection, Error> = self.lock.withLock {
            if self.connectResults.isEmpty {
                let connection = FakeGrokSTTWebSocketConnection()
                self.connections.append(connection)
                return .success(connection)
            }
            let next = self.connectResults.removeFirst()
            if case let .success(connection) = next {
                self.connections.append(connection)
            }
            return next
        }
        return try result.get()
    }

    private func awaitHangingConnect() async throws -> FakeGrokSTTWebSocketConnection {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.lock.lock()
                if Task.isCancelled {
                    self.connectWasCancelled = true
                    self.lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.hangingContinuations.append(continuation)
                self.lock.unlock()
                self.connectStarted.signal()
            }
        } onCancel: {
            self.lock.lock()
            self.connectWasCancelled = true
            let waiters = self.hangingContinuations
            self.hangingContinuations = []
            self.lock.unlock()
            waiters.forEach { $0.resume(throwing: CancellationError()) }
        }
    }
}

final class FakeGrokSTTHTTPClient: GrokSTTHTTPPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<(Data, URLResponse), Error>] = []
    private(set) var requests: [URLRequest] = []

    func enqueue(status: Int, json: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(
            url: GrokSTTRESTClient.endpoint,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        self.lock.withLock { self.results.append(.success((data, response))) }
    }

    func enqueueFailure(_ error: Error) {
        self.lock.withLock { self.results.append(.failure(error)) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let result: Result<(Data, URLResponse), Error> = self.lock.withLock {
            self.requests.append(request)
            if self.results.isEmpty {
                return .failure(GrokSTTError.offline)
            }
            return self.results.removeFirst()
        }
        return try result.get()
    }
}

final class RecordingGrokSTTResolver: GrokSTTCredentialResolving, @unchecked Sendable {
    private let lock = NSLock()
    var isSourceConfigured: Bool
    var credential: GrokSTTCredential
    var alternate: GrokSTTCredential?
    var resolveDelayNanoseconds: UInt64 = 0
    private(set) var unauthorizedCallCount = 0

    init(
        source: GrokSTTCredentialSource = .apiKey,
        bearer: String = "xai-stt-test-key",
        alternateBearer: String? = nil
    ) {
        self.isSourceConfigured = true
        self.credential = GrokSTTCredential(
            bearer: bearer,
            source: source,
            expiresAt: nil,
            accountLabel: "test"
        )
        if let alternateBearer {
            self.alternate = GrokSTTCredential(
                bearer: alternateBearer,
                source: source,
                expiresAt: nil,
                accountLabel: "alt"
            )
        }
    }

    func resolveCredential() async throws -> GrokSTTCredential {
        let delay = self.resolveDelayNanoseconds
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        return self.credential
    }

    func resolveCredentialAfterUnauthorized(rejectedBearerFingerprint: String) async throws -> GrokSTTCredential {
        _ = rejectedBearerFingerprint
        self.lock.withLock { self.unauthorizedCallCount += 1 }
        if let alternate {
            return alternate
        }
        throw GrokSTTError.unauthorized
    }
}

func grokSTTWaitUntil(timeout: TimeInterval = 1, predicate: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return predicate()
}

final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            if self.isOpen {
                self.lock.unlock()
                continuation.resume()
                return
            }
            self.waiters.append(continuation)
            self.lock.unlock()
        }
    }

    func signal() {
        self.lock.lock()
        self.isOpen = true
        let waiters = self.waiters
        self.waiters = []
        self.lock.unlock()
        waiters.forEach { $0.resume() }
    }
}

func grokSTTAssertEventually(
    _ message: String = "condition was not met in time",
    timeout: TimeInterval = 1,
    file: StaticString = #filePath,
    line: UInt = #line,
    predicate: @escaping () -> Bool
) async {
    let ok = await grokSTTWaitUntil(timeout: timeout, predicate: predicate)
    XCTAssertTrue(ok, message, file: file, line: line)
}
