import Foundation

/// Grok STT diagnostics. `source` is always `"GrokSTT"`.
/// Never logs Bearer tokens, `Authorization` values, `key`, `auth.json` excerpts, or request bodies.
nonisolated enum GrokSTTLog {
    static let source = "GrokSTT"

    static func info(_ message: String) {
        DebugLogger.shared.info(self.redact(message), source: self.source)
    }

    static func debug(_ message: String) {
        DebugLogger.shared.debug(self.redact(message), source: self.source)
    }

    static func error(_ message: String) {
        DebugLogger.shared.error(self.redact(message), source: self.source)
    }

    static func redact(_ message: String) -> String {
        GrokSTTError.sanitizedMessage(message)
    }

    /// Milliseconds since `date`, or `-1` when missing.
    static func milliseconds(since date: Date?) -> Int {
        guard let date else { return -1 }
        return Int((Date().timeIntervalSince(date) * 1000).rounded())
    }

    static func truncatedTranscript(_ text: String, limit: Int = 80) -> String {
        let sanitized = self.redact(text)
        if sanitized.count <= limit {
            return sanitized
        }
        return String(sanitized.prefix(limit)) + "…"
    }

    /// URLRequest dump for debug logs. Masks auth headers. **Never includes the body**
    /// (STT requests are multipart PCM/WAV). Dedicated STT dump — not the LLM chat cURL helper.
    static func describeRequest(_ request: URLRequest) -> String {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? ""
        var lines = ["\(method) \(url)"]
        let headers = request.allHTTPHeaderFields ?? [:]
        for key in headers.keys.sorted() {
            let value = headers[key] ?? ""
            lines.append("\(key): \(Self.maskedHeaderValue(name: key, value: value))")
        }
        lines.append("(body omitted)")
        return self.redact(lines.joined(separator: "\n"))
    }

    static func maskedHeaderValue(name: String, value: String) -> String {
        let lower = name.lowercased()
        if lower.contains("auth") || lower.contains("cookie") {
            return "Bearer [REDACTED]"
        }
        return value
    }
}
