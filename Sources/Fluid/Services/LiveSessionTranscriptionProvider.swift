import Foundation

/// A provider that keeps per-recording state outside the shared PCM buffer, such as
/// a cloud streaming connection. ASRService tells it when a dictation recording
/// starts and when one is discarded; the recording ends through `transcribeFinal`.
protocol LiveSessionTranscriptionProvider: TranscriptionProvider {
    /// Called before capture starts for a dictation recording (never for training captures).
    func recordingSessionWillStart()

    /// Called when a recording is discarded without a final transcription.
    func recordingSessionDidCancel()
}
