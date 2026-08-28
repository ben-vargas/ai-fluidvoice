import Foundation

/// User-facing copy for Grok meeting/file REST and LocalAPI `/v1/transcribe`.
/// Video extract+REST is allowed only after this notice; containers are never POSTed.
nonisolated enum GrokSTTCloudUploadCopy {
    static let audioNotice = "This audio file will be sent to xAI for transcription."
    static let videoNotice = "This video will be decoded on your Mac; the extracted audio will be sent to xAI."
    static let localAPITranscribeNotice =
        "The selected voice engine is used. Grok Speech (xAI) sends audio to xAI. There is no local fallback."
    static let speakerLabelsUnavailable =
        "Speaker labels stay on local engines. Grok Speech does not send diarize to xAI."

    static func meetingNotice(isVideo: Bool) -> String {
        isVideo ? self.videoNotice : self.audioNotice
    }

    static func localAPIErrorMessage(_ error: Error, isCloudEngine: Bool) -> String {
        let base = error.localizedDescription
        guard isCloudEngine else { return base }
        return "\(base) \(self.localAPITranscribeNotice)"
    }
}
