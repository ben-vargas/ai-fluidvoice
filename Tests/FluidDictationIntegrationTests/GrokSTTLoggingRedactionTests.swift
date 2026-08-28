@testable import FluidVoice_Debug
import XCTest

final class GrokSTTLoggingRedactionTests: XCTestCase {
    func testDescribeRequestMasksAuthorizationAndOmitsBody() {
        var request = URLRequest(url: GrokSTTRESTClient.endpoint)
        request.httpMethod = "POST"
        let secret = "supersecret-token-value-12345678901234567890"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=abc", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("Bearer \(secret) RIFF WAV payload \(secret)".utf8)

        let dump = GrokSTTLog.describeRequest(request)
        XCTAssertTrue(dump.contains("POST "))
        XCTAssertTrue(dump.contains("api.x.ai"))
        XCTAssertTrue(dump.contains("(body omitted)"))
        XCTAssertTrue(dump.localizedCaseInsensitiveContains("redacted"))
        XCTAssertFalse(dump.contains(secret))
        XCTAssertFalse(dump.localizedCaseInsensitiveContains("Bearer \(secret)"))
        XCTAssertFalse(dump.contains("RIFF"))
        XCTAssertFalse(dump.contains("WAV payload"))
        XCTAssertFalse(dump.contains("httpBody"))
        XCTAssertEqual(GrokSTTLog.source, "GrokSTT")
    }

    func testDescribeRequestMasksCookieHeaders() {
        var request = URLRequest(url: GrokSTTWebSocketSession.endpoint)
        request.setValue("session=abc123; auth=xyz", forHTTPHeaderField: "Cookie")
        let dump = GrokSTTLog.describeRequest(request)
        XCTAssertFalse(dump.contains("abc123"))
        XCTAssertFalse(dump.contains("session="))
        XCTAssertTrue(dump.localizedCaseInsensitiveContains("redacted"))
    }

    func testRedactStripsBearerAndAuthJSON() {
        let payload = #"Bearer supersecret-token-value-12345678901234567890 {"key":"cli-store-secret"}"#
        let redacted = GrokSTTLog.redact(payload)
        XCTAssertFalse(redacted.localizedCaseInsensitiveContains("Bearer"))
        XCTAssertFalse(redacted.contains("supersecret-token-value"))
        XCTAssertFalse(redacted.contains("cli-store-secret"))
    }

    func testTruncatedTranscriptDoesNotKeepSecrets() {
        let text = "hello Bearer supersecret-token-value-12345678901234567890 world"
        let truncated = GrokSTTLog.truncatedTranscript(text, limit: 40)
        XCTAssertFalse(truncated.contains("supersecret-token-value"))
        XCTAssertLessThanOrEqual(truncated.count, 41)
    }

    func testWebSocketRequestDumpDoesNotLogToken() {
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
        let dump = GrokSTTLog.describeRequest(request)
        XCTAssertFalse(dump.contains("super-secret-token-value"))
        XCTAssertTrue(dump.localizedCaseInsensitiveContains("redacted"))
        XCTAssertTrue(dump.contains("(body omitted)"))
    }

    func testRESTRequestDumpOmitsMultipartAndToken() async throws {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 200, json: ["text": "ok"])
        let resolver = RecordingGrokSTTResolver(bearer: "supersecret-token-value-12345678901234567890")
        let client = GrokSTTRESTClient(resolver: resolver, http: http)
        _ = try await client.transcribePCM([0.1, 0.2], languageCode: nil)
        XCTAssertEqual(http.requests.count, 1)
        let dump = GrokSTTLog.describeRequest(http.requests[0])
        XCTAssertFalse(dump.contains("supersecret-token-value"))
        XCTAssertTrue(dump.contains("(body omitted)"))
        XCTAssertFalse(dump.contains("RIFF"))
        XCTAssertFalse(dump.contains("name=\"file\""))
        XCTAssertTrue(dump.localizedCaseInsensitiveContains("redacted"))
    }

    func testGrokSTTSourcesDoNotReuseLLMClientLogRequest() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()
        let grokDir = repoRoot.appendingPathComponent("Sources/Fluid/Services/GrokSTT")
        let extra = [
            repoRoot.appendingPathComponent("Sources/Fluid/Services/StreamingTranscriptionSession.swift"),
        ]
        let enumerator = FileManager.default.enumerator(at: grokDir, includingPropertiesForKeys: nil)
        var files: [URL] = extra
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" {
                files.append(url)
            }
        }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                source.contains("LLMClient."),
                "\(file.lastPathComponent) must not call LLMClient"
            )
            XCTAssertFalse(
                source.contains(".logRequest("),
                "\(file.lastPathComponent) must not call logRequest"
            )
        }
    }
}
