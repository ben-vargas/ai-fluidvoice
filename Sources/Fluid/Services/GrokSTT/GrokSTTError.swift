import Foundation

/// Typed STT failures. Payloads never include Bearer tokens, `key`, cookies, or `auth.json` excerpts.
/// `asNSError().userInfo` contains only `NSLocalizedDescriptionKey` so `ASRService.stop` logging is safe.
nonisolated enum GrokSTTError: Error, LocalizedError, Equatable, Sendable {
    case noCredentialConfigured
    case grokCLINotFound
    case grokStoreUnreadable
    case grokStoreParseFailed
    case grokSessionExpired
    case refreshInProgress
    case unauthorized
    case forbidden
    case rateLimited(retryAfter: TimeInterval?)
    case timeout
    case offline
    case server(status: Int, message: String)
    case socketClosed(code: Int)
    case emptyTranscript
    case cancelled
    case invalidAudio
    case fileTooLarge
    case unsupportedFile
    case dictionaryTrainingUnsupported
    case videoUploadForbidden

    var numericCode: Int {
        switch self {
        case .noCredentialConfigured: return 1001
        case .grokCLINotFound: return 1002
        case .grokStoreUnreadable: return 1003
        case .grokStoreParseFailed: return 1004
        case .grokSessionExpired: return 1005
        case .refreshInProgress: return 1006
        case .unauthorized: return 1401
        case .forbidden: return 1403
        case .rateLimited: return 1429
        case .timeout: return 1501
        case .offline: return 1502
        case .server: return 1500
        case .socketClosed: return 1503
        case .emptyTranscript: return 1601
        case .cancelled: return 1602
        case .invalidAudio: return 1603
        case .fileTooLarge: return 1413
        case .unsupportedFile: return 1604
        case .dictionaryTrainingUnsupported: return 1605
        case .videoUploadForbidden: return 1606
        }
    }

    var errorDescription: String? {
        switch self {
        case .noCredentialConfigured:
            return "Add an xAI API key or a Grok CLI session in Voice Engine settings."
        case .grokCLINotFound:
            return "Open Grok Build once (or set the grok CLI path in Voice Engine settings) so FluidVoice can refresh your session."
        case .grokStoreUnreadable:
            return "Couldn't read your Grok CLI session store."
        case .grokStoreParseFailed:
            return "Your Grok CLI session store is unreadable."
        case .grokSessionExpired:
            return "Grok session expired — open Grok Build once, then Retry."
        case .refreshInProgress:
            return "Grok session refresh is still running. Try again in a moment."
        case .unauthorized:
            return "xAI rejected the speech-to-text credential (401)."
        case .forbidden:
            return "xAI denied this speech-to-text request (403)."
        case .rateLimited:
            return "xAI rate-limited speech-to-text. Wait and tap Retry."
        case .timeout:
            return "Timed out waiting for Grok speech-to-text."
        case .offline:
            return "Couldn't reach xAI. Your recording is kept — Retry sends it again."
        case let .server(status, message):
            let sanitized = Self.sanitizedMessage(message)
            if sanitized.isEmpty {
                return "Grok speech-to-text failed (HTTP \(status))."
            }
            return "Grok speech-to-text failed (HTTP \(status)). \(sanitized)"
        case let .socketClosed(code):
            return "The Grok speech connection closed unexpectedly (\(code))."
        case .emptyTranscript:
            return "Grok returned no transcript."
        case .cancelled:
            return "Speech-to-text was cancelled."
        case .invalidAudio:
            return "That audio couldn't be transcribed."
        case .fileTooLarge:
            return "That file is too large for Grok speech-to-text (500 MB limit)."
        case .unsupportedFile:
            return "That file type isn't supported for Grok speech-to-text."
        case .dictionaryTrainingUnsupported:
            return "Grok Speech doesn't support pronunciation training."
        case .videoUploadForbidden:
            return "Video files aren't uploaded to xAI. Extracted audio can be sent after you confirm."
        }
    }

    /// Bridge for ASRService NSError logging. `userInfo` contains ONLY `NSLocalizedDescriptionKey`.
    func asNSError() -> NSError {
        NSError(
            domain: Self.nsErrorDomain,
            code: self.numericCode,
            userInfo: [NSLocalizedDescriptionKey: self.errorDescription ?? "Speech-to-text failed."]
        )
    }

    static let nsErrorDomain = "GrokSTT"

    /// Map HTTP status to a typed error. 403 is never retried by callers.
    static func fromHTTPStatus(
        _ status: Int,
        message: String = "",
        retryAfter: TimeInterval? = nil
    ) -> GrokSTTError {
        switch status {
        case 400:
            return .invalidAudio
        case 401:
            return .unauthorized
        case 403:
            return .forbidden
        case 413:
            return .fileTooLarge
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        default:
            if (500...599).contains(status) {
                return .server(status: status, message: message)
            }
            return .server(status: status, message: message)
        }
    }

    static func sanitizedMessage(_ message: String) -> String {
        var result = message
        for pattern in Self.redactionPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "[redacted]")
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 180 {
            return String(trimmed.prefix(180))
        }
        return trimmed
    }

    private static let redactionPatterns = [
        #"(?i)bearer\s+\S+"#,
        #"(?i)authorization:\s*\S+"#,
        #"\bxai-[A-Za-z0-9_-]{8,}\b"#,
        #"(?i)refresh_token"#,
        #"[A-Za-z0-9_-]{40,}"#,
    ]
}
