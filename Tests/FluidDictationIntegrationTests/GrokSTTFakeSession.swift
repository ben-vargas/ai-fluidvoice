@testable import FluidVoice_Debug
import Foundation
import XCTest

/// In-memory streaming session for unit tests. Production `GrokSTTProvider` must not return this.
final nonisolated class GrokSTTFakeSession: StreamingTranscriptionSession, @unchecked Sendable {
    enum State: String, Sendable {
        case idle
        case waitCreated
        case streaming
        case finishing
        case complete
        case cancelled
        case failed
    }

    struct Configuration: Sendable {
        var createdDelay: TimeInterval = 0
        var finishDelay: TimeInterval = 0
        var startError: GrokSTTError?
        var failBeforeAudioDone: GrokSTTError?
        var neverCreated: Bool = false
        var createdTimeout: TimeInterval = 20
        var transcriptOnFinish: String?
        var blockAppend: Bool = false
        /// `start()` stays in `waitCreated` until `cancel()`; Task cancellation is ignored.
        var startUntilCancelled: Bool = false
        /// Enter `streaming` before `createdDelay` elapses so stop can race the created gate.
        var enterStreamingBeforeReturn: Bool = false
        /// Park `finish()` after it has been entered so tests can observe start-blocked finalization.
        var finishPark: TestLatch? = nil
        /// Keep `blockAppend` held across `cancel()` so tests can observe cancel ownership.
        var holdAppendAcrossCancel: Bool = false
    }

    private let lock = NSLock()
    private var assembler = GrokSTTTranscriptAssembler()
    private var state: State = .idle
    private var stickyError: GrokSTTError?
    private var handoffSamples: [Float] = []
    private var createdContinuation: CheckedContinuation<Void, Error>?
    private var appendBlocked = false
    private var appendBlockConsumed = false
    private var onPartialHandler: (@MainActor (String) -> Void)?

    private(set) var appendedFrames: [Data] = []
    private(set) var audioDoneSent = false
    private(set) var appendCallCount = 0
    private(set) var finishCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var handoffCallCount = 0
    private var queuedCount = 0

    let configuration: Configuration

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    var transcript: String {
        self.lock.withLock { self.assembler.transcript }
    }

    var transportError: GrokSTTError? {
        self.lock.withLock { self.stickyError }
    }

    var onPartial: (@MainActor (String) -> Void)? {
        get { self.lock.withLock { self.onPartialHandler } }
        set { self.lock.withLock { self.onPartialHandler = newValue } }
    }

    var queuedAudioFrameCount: Int {
        self.lock.withLock { self.queuedCount }
    }

    var currentState: State {
        self.lock.withLock { self.state }
    }

    var handoffPCM: [Float] {
        self.lock.withLock { self.handoffSamples }
    }

    var appendedSampleCount: Int {
        self.lock.withLock { self.appendedFrames.reduce(0) { $0 + ($1.count / 2) } }
    }

    func setQueuedAudioFrameCount(_ count: Int) {
        self.lock.withLock { self.queuedCount = count }
    }

    @concurrent func start() async throws {
        XCTAssertFalse(
            Thread.isMainThread,
            "StreamingTranscriptionSession.start() must run off the main thread"
        )
        self.lock.withLock {
            if self.state == .idle {
                self.state = .waitCreated
            }
        }

        if self.configuration.startUntilCancelled {
            try await self.waitUntilCreated()
            throw GrokSTTError.cancelled
        }

        if self.configuration.neverCreated {
            try await Task.sleep(nanoseconds: UInt64(max(self.configuration.createdTimeout, 0.05) * 1_000_000_000))
            throw GrokSTTError.timeout
        }

        if self.configuration.enterStreamingBeforeReturn {
            self.lock.withLock {
                if self.state == .waitCreated || self.state == .idle {
                    self.state = .streaming
                }
            }
        }

        if self.configuration.createdDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(self.configuration.createdDelay * 1_000_000_000))
        }

        try Task.checkCancellation()

        if let startError = self.configuration.startError {
            self.fail(startError)
            throw startError
        }

        let cancelled = self.lock.withLock { self.state == .cancelled }
        if cancelled {
            throw GrokSTTError.cancelled
        }

        self.lock.withLock {
            if self.state == .waitCreated || self.state == .idle {
                self.state = .streaming
            }
            let continuation = self.createdContinuation
            self.createdContinuation = nil
            continuation?.resume()
        }
    }

    func append(pcm16: Data) {
        let shouldBlock: Bool = self.lock.withLock {
            self.appendCallCount += 1
            if self.state != .streaming {
                return false
            }
            self.appendedFrames.append(pcm16)
            if self.configuration.blockAppend, !self.appendBlockConsumed {
                self.appendBlockConsumed = true
                self.appendBlocked = true
                return true
            }
            return false
        }

        if shouldBlock {
            while true {
                if Task.isCancelled, !self.configuration.holdAppendAcrossCancel { break }
                let stillBlocked = self.lock.withLock { self.appendBlocked }
                if !stillBlocked { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    func handoffUnsentPCM(_ samples: [Float]) {
        self.lock.withLock {
            self.handoffCallCount += 1
            if self.state == .streaming, !self.appendedFrames.isEmpty {
                return
            }
            guard self.state == .waitCreated
                || self.state == .idle
                || self.state == .streaming
            else {
                return
            }
            self.handoffSamples = samples
        }
    }

    @concurrent func finish() async throws -> String {
        XCTAssertFalse(
            Thread.isMainThread,
            "StreamingTranscriptionSession.finish() must run off the main thread"
        )
        self.lock.withLock { self.finishCallCount += 1 }

        if self.configuration.neverCreated {
            throw GrokSTTError.timeout
        }

        try await self.waitUntilCreated()

        if let finishPark = self.configuration.finishPark {
            await finishPark.park()
        }

        if self.configuration.finishDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(self.configuration.finishDelay * 1_000_000_000))
        }

        if let preDone = self.configuration.failBeforeAudioDone {
            self.fail(preDone)
            throw preDone
        }

        let samples = self.lock.withLock { () -> [Float] in
            if self.state == .cancelled {
                return []
            }
            self.state = .finishing
            return self.handoffSamples
        }

        if !samples.isEmpty {
            let frameSize = GrokSTTAudioConverter.samplesPerFrame
            var offset = 0
            while offset < samples.count {
                let end = min(offset + frameSize, samples.count)
                let slice = Array(samples[offset..<end])
                self.lock.withLock {
                    self.appendedFrames.append(GrokSTTAudioConverter.pcm16LE(fromFloat32: slice))
                }
                offset = end
            }
        }

        self.lock.withLock { self.audioDoneSent = true }

        if let forced = self.configuration.transcriptOnFinish {
            self.lock.withLock { self.assembler.replaceWithServerText(forced) }
        }

        let assembled = self.transcript
        if assembled.isEmpty {
            self.lock.withLock { self.state = .complete }
            throw GrokSTTError.timeout
        }
        self.lock.withLock { self.state = .complete }
        return assembled
    }

    func cancel() {
        self.lock.withLock {
            self.cancelCallCount += 1
            self.state = .cancelled
            let continuation = self.createdContinuation
            self.createdContinuation = nil
            continuation?.resume(throwing: GrokSTTError.cancelled)
        }
        if !self.configuration.holdAppendAcrossCancel {
            self.unblockAppend()
        }
    }

    func recordPartial(start: Double, text: String) {
        let snapshot: String = self.lock.withLock {
            self.assembler.record(start: start, text: text)
            return self.assembler.transcript
        }
        let handler = self.onPartial
        guard !snapshot.isEmpty, let handler else { return }
        Task { @MainActor in
            handler(snapshot)
        }
    }

    func fail(_ error: GrokSTTError) {
        self.lock.withLock {
            if self.stickyError == nil {
                self.stickyError = error
            }
            if self.state != .cancelled, self.state != .complete {
                self.state = .failed
            }
            let continuation = self.createdContinuation
            self.createdContinuation = nil
            continuation?.resume(throwing: error)
        }
        self.unblockAppend()
    }

    var isAppendBlocked: Bool {
        self.lock.withLock { self.appendBlocked }
    }

    func unblockAppend() {
        self.lock.withLock { self.appendBlocked = false }
    }

    private func waitUntilCreated() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.withLock {
                if self.state == .streaming || self.state == .finishing || self.state == .complete {
                    continuation.resume()
                } else if self.state == .cancelled {
                    continuation.resume(throwing: GrokSTTError.cancelled)
                } else if let error = self.stickyError {
                    continuation.resume(throwing: error)
                } else if self.configuration.neverCreated {
                    continuation.resume(throwing: GrokSTTError.timeout)
                } else {
                    self.createdContinuation = continuation
                }
            }
        }
    }

}
