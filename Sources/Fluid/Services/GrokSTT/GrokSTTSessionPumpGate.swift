import Foundation

/// Lock-protected pump state so the PCM loop can run off MainActor.
final nonisolated class GrokSTTSessionPumpGate: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var created = false
    private var error: GrokSTTError?
    private var sentCursor = 0

    struct Snapshot: Sendable {
        var isRunning: Bool
        var createdReceived: Bool
        var transportError: GrokSTTError?
        var sentCursor: Int
    }

    func begin() {
        self.lock.withLock {
            self.running = true
            self.created = false
            self.error = nil
            self.sentCursor = 0
        }
    }

    func requestStop() {
        self.lock.withLock { self.running = false }
    }

    func markCreated() {
        self.lock.withLock { self.created = true }
    }

    func setTransportError(_ error: GrokSTTError) {
        self.lock.withLock {
            if self.error == nil {
                self.error = error
            }
        }
    }

    func advanceSentCursor(_ count: Int) {
        self.lock.withLock { self.sentCursor += count }
    }

    var snapshot: Snapshot {
        self.lock.withLock {
            Snapshot(
                isRunning: self.running,
                createdReceived: self.created,
                transportError: self.error,
                sentCursor: self.sentCursor
            )
        }
    }
}

nonisolated enum GrokSTTSessionPump {
    static let sendQueuePauseLimit = 20

    static func run(
        audioBuffer: ThreadSafeAudioBuffer,
        gate: GrokSTTSessionPumpGate,
        session: StreamingTranscriptionSession
    ) async {
        while !Task.isCancelled {
            let snapshot = gate.snapshot
            if !snapshot.isRunning { break }
            if snapshot.transportError != nil || session.transportError != nil { break }

            let capturedCursor = audioBuffer.count
            if snapshot.createdReceived {
                var sentCursor = snapshot.sentCursor
                while capturedCursor - sentCursor >= GrokSTTAudioConverter.samplesPerFrame {
                    if session.queuedAudioFrameCount > Self.sendQueuePauseLimit {
                        break
                    }
                    let slice = audioBuffer.getRange(
                        startingAt: sentCursor,
                        count: GrokSTTAudioConverter.samplesPerFrame
                    )
                    guard slice.count == GrokSTTAudioConverter.samplesPerFrame else { break }
                    session.append(pcm16: GrokSTTAudioConverter.pcm16LE(fromFloat32: slice[...]))
                    gate.advanceSentCursor(GrokSTTAudioConverter.samplesPerFrame)
                    sentCursor += GrokSTTAudioConverter.samplesPerFrame
                }
            }

            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
