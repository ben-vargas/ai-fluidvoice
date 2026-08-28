import Foundation

/// Push-based live transcription. Parallel to pull `TranscriptionProvider`.
/// Adopted only by cloud session engines. Local engines do not conform.
/// NOT @MainActor — REST via TranscriptionExecutor would deadlock if it were.
nonisolated protocol StreamingTranscriptionProviding: TranscriptionProvider {
    func makeStreamingSession(
        configuration: StreamingSTTSessionConfiguration
    ) throws -> StreamingTranscriptionSession
}

nonisolated struct StreamingSTTSessionConfiguration: Sendable, Equatable {
    var sampleRate: Int
    var languageCode: String?
    var keyterms: [String]
    var interimResults: Bool

    static let grokDictation = StreamingSTTSessionConfiguration(
        sampleRate: 16_000,
        languageCode: nil,
        keyterms: [],
        interimResults: true
    )
}

/// One dictation = one session. Not reused across recordings.
/// Isolated to the session’s URLSession delegate queue, not MainActor.
nonisolated protocol StreamingTranscriptionSession: AnyObject {
    /// Last-write-wins assembled text. Empty interims are suppressed by the assembler.
    /// Thread-safe snapshot (session queue lock).
    var transcript: String { get }

    /// Sticky transport error for the pump (`Task<Void, Never>` cannot throw).
    var transportError: GrokSTTError? { get }

    /// Fires on every non-empty assembled snapshot. Session hops to MainActor.
    var onPartial: (@MainActor (String) -> Void)? { get set }

    /// Connect + wait for `transcript.created`. Safe to call off-main.
    /// Does not send audio. Reconnects once on HTTP-upgrade 401 (CLI alternate Bearer).
    func start() async throws

    /// Enqueue a binary PCM16 LE frame (non-blocking). Legal **only in `streaming`**
    /// (`transcript.created` received, `finish`/`cancel` not yet called).
    /// Must not be awaited on MainActor. No-op (debug assert) if called in `waitCreated`.
    func append(pcm16: Data)

    /// Store unsent Float32 (the **entire** utterance). Replaces any previous handoff.
    /// `finish()` will convert and send from sample 0 after `created`. Legal in
    /// `waitCreated`, and in `streaming` only when zero frames have been appended
    /// (created raced stop; pump sent nothing). Illegal once the pump has appended.
    /// Does not read `ASRService.audioBuffer`.
    func handoffUnsentPCM(_ samples: [Float])

    /// Send `{"type":"audio.done"}`, wait for `transcript.done` (or timeout with non-empty
    /// assembled text = success). Returns assembled / server text. Throws if nothing produced.
    /// Never reads `ASRService.audioBuffer`. If `handoffUnsentPCM` was called, send that
    /// copy from sample 0 after `created`, then `audio.done`.
    func finish() async throws -> String

    /// Drop the socket. Do not send `audio.done`. Idempotent. Does not wait for close.
    func cancel()

    /// Frames queued for send. Pump pauses when this exceeds 20; it must not drop-oldest.
    var queuedAudioFrameCount: Int { get }
}
