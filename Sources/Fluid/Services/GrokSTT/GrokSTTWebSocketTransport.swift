import Foundation

nonisolated enum GrokSTTWebSocketMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

nonisolated protocol GrokSTTWebSocketConnection: AnyObject {
    func send(data: Data) async throws
    func send(text: String) async throws
    func receive() async throws -> GrokSTTWebSocketMessage
    func close()
}

nonisolated protocol GrokSTTWebSocketTransporting: AnyObject, Sendable {
    func connect(request: URLRequest) async throws -> any GrokSTTWebSocketConnection
}

nonisolated enum GrokSTTTransportErrorMapper {
    static func map(_ error: Error, httpStatus: Int? = nil) -> GrokSTTError {
        if let grok = error as? GrokSTTError {
            return grok
        }
        if let httpStatus {
            return GrokSTTError.fromHTTPStatus(httpStatus)
        }
        if let status = Self.httpStatus(from: error) {
            return GrokSTTError.fromHTTPStatus(status)
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDataNotAllowed,
                 NSURLErrorInternationalRoamingOff,
                 NSURLErrorCallIsActive,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorTimedOut:
                return .offline
            default:
                break
            }
        }
        return .socketClosed(code: ns.code)
    }

    static func httpStatus(from error: Error) -> Int? {
        let ns = error as NSError
        for key in ["NSErrorFailingURLResponseKey", "NSURLErrorFailingURLResponseErrorKey"] {
            if let response = ns.userInfo[key] as? HTTPURLResponse {
                return response.statusCode
            }
        }
        for value in ns.userInfo.values {
            if let response = value as? HTTPURLResponse {
                return response.statusCode
            }
        }
        return nil
    }
}

/// Production WebSocket transport. Lives off MainActor on a dedicated delegate queue.
final nonisolated class GrokSTTURLSessionWebSocketTransport: NSObject, GrokSTTWebSocketTransporting, @unchecked Sendable {
    static let connectTimeout: TimeInterval = 20

    func connect(request: URLRequest) async throws -> any GrokSTTWebSocketConnection {
        let connection = GrokSTTURLSessionWebSocketConnection()
        try await connection.open(request: request)
        return connection
    }
}

final nonisolated class GrokSTTURLSessionWebSocketConnection: NSObject, URLSessionWebSocketDelegate, GrokSTTWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var urlSession: URLSession?
    private var task: URLSessionWebSocketTask?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var didResumeOpen = false
    private var closed = false
    private var httpStatus: Int?

    func open(request: URLRequest) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = GrokSTTURLSessionWebSocketTransport.connectTimeout
        configuration.timeoutIntervalForResource = GrokSTTURLSessionWebSocketTransport.connectTimeout

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.webSocketTask(with: request)
            self.lock.lock()
            self.openContinuation = continuation
            self.urlSession = session
            self.task = task
            self.lock.unlock()
            task.resume()
        }
    }

    func send(data: Data) async throws {
        let task = try self.requireTask()
        try await task.send(.data(data))
    }

    func send(text: String) async throws {
        let task = try self.requireTask()
        try await task.send(.string(text))
    }

    func receive() async throws -> GrokSTTWebSocketMessage {
        let task = try self.requireTask()
        let message = try await task.receive()
        switch message {
        case let .string(text):
            return .text(text)
        case let .data(data):
            return .data(data)
        @unknown default:
            throw GrokSTTError.socketClosed(code: 0)
        }
    }

    func close() {
        self.lock.lock()
        self.closed = true
        let task = self.task
        let session = self.urlSession
        self.task = nil
        self.urlSession = nil
        self.lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocolString: String?
    ) {
        _ = protocolString
        self.resumeOpen(.success(()))
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        _ = reason
        let error = GrokSTTError.socketClosed(code: Int(closeCode.rawValue))
        self.resumeOpen(.failure(error))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let response = task.response as? HTTPURLResponse {
            self.lock.withLock { self.httpStatus = response.statusCode }
        }
        if let error {
            let status = self.lock.withLock { self.httpStatus }
            self.resumeOpen(.failure(GrokSTTTransportErrorMapper.map(error, httpStatus: status)))
            return
        }
        if let status = self.lock.withLock({ self.httpStatus }), status >= 400 {
            self.resumeOpen(.failure(GrokSTTError.fromHTTPStatus(status)))
        }
    }

    private func requireTask() throws -> URLSessionWebSocketTask {
        try self.lock.withLock { () -> URLSessionWebSocketTask in
            if self.closed {
                throw GrokSTTError.cancelled
            }
            guard let task = self.task else {
                throw GrokSTTError.socketClosed(code: 0)
            }
            return task
        }
    }

    private func resumeOpen(_ result: Result<Void, Error>) {
        self.lock.lock()
        guard !self.didResumeOpen else {
            self.lock.unlock()
            return
        }
        self.didResumeOpen = true
        let continuation = self.openContinuation
        self.openContinuation = nil
        self.lock.unlock()
        continuation?.resume(with: result)
    }
}
