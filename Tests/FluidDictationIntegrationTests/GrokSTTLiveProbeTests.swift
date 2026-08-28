@testable import FluidVoice_Debug
import XCTest

/// Opt-in live probes (L1, L3, L6, L7, L12, L13). Never run in CI.
/// Set `GROK_STT_LIVE=1`. Does not reuse LLM Keychain `com.fluidvoice.provider-api-keys`.
final class GrokSTTLiveProbeTests: XCTestCase {
    func testL1APIKeyRESTPCMAndEmptyAudio() async throws {
        try Self.requireLive()
        let key = try Self.requireSTTAPIKey()
        let resolver = RecordingGrokSTTResolver(source: .apiKey, bearer: key)
        let http = CountingGrokSTTHTTPClient(inner: GrokSTTURLSessionHTTPClient())
        let client = GrokSTTRESTClient(resolver: resolver, http: http)
        let samples = try Self.fixtureSamples()
        let result = try await client.transcribePCM(samples, languageCode: nil)
        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(http.lastStatus, 200)

        http.reset()
        let emptyWAV = GrokSTTAudioConverter.wav(fromFloat32: [])
        do {
            _ = try await client.transcribeWAV(
                emptyWAV,
                filename: "empty.wav",
                languageCode: nil,
                keyterms: [],
                credential: nil,
                timeout: GrokSTTRESTClient.dictationTimeout
            )
            XCTFail("empty audio must not return a transcript")
        } catch {
            Self.assertEmptyAudio4xx(status: http.lastStatus, error: error)
        }
        XCTAssertEqual(resolver.unauthorizedCallCount, 0, "L1 must not fail over to a CLI session")
    }

    func testL3CLITokenREST() async throws {
        try Self.requireLive()
        let resolver = try Self.cliResolver()
        guard resolver.isSourceConfigured else {
            throw XCTSkip("No Grok CLI session configured for L3")
        }
        let client = GrokSTTRESTClient(resolver: resolver, http: GrokSTTURLSessionHTTPClient())
        let samples = try Self.fixtureSamples()
        let result = try await client.transcribePCM(samples, languageCode: nil)
        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testL6BadAPIKeyIsUnauthorizedWithoutCLIFailover() async throws {
        try Self.requireLive()
        let resolver = RecordingGrokSTTResolver(
            source: .apiKey,
            bearer: "xai-invalid-live-probe-key",
            alternateBearer: "xai-also-invalid-unused"
        )
        let client = GrokSTTRESTClient(resolver: resolver, http: GrokSTTURLSessionHTTPClient())
        let samples = try Self.fixtureSamples()
        do {
            _ = try await client.transcribePCM(samples, languageCode: nil)
            XCTFail("bad API key must not succeed")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .unauthorized)
        }
        XCTAssertEqual(resolver.unauthorizedCallCount, 0)
    }

    /// L7: live 403 must not retry (CLI alternate unused). xAI 403 is not inducible
    /// with a working STT credential; set `GROK_STT_LIVE_FORBIDDEN_BEARER` to a token
    /// that returns HTTP 403 from `POST /v1/stt`. A skip here is blocked/unrun, not coverage.
    /// No-retry remains unit-covered by `test403DoesNotRetry`.
    func testL7ForbiddenDoesNotRetry() async throws {
        try Self.requireLive()
        let forbidden = ProcessInfo.processInfo.environment["GROK_STT_LIVE_FORBIDDEN_BEARER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !forbidden.isEmpty else {
            throw XCTSkip(
                "L7 blocked/unrun: set GROK_STT_LIVE_FORBIDDEN_BEARER to a token that returns HTTP 403 from POST /v1/stt. No-retry is unit-covered by test403DoesNotRetry; this skip is not L7 coverage."
            )
        }
        let http = CountingGrokSTTHTTPClient(inner: GrokSTTURLSessionHTTPClient())
        let resolver = RecordingGrokSTTResolver(
            source: .grokCLISession,
            bearer: forbidden,
            alternateBearer: "grok-stt-l7-unused-alternate"
        )
        let client = GrokSTTRESTClient(resolver: resolver, http: http)
        let samples = try Self.fixtureSamples()
        do {
            _ = try await client.transcribePCM(samples, languageCode: nil)
            XCTFail("L7 forbidden bearer must not succeed")
        } catch {
            let status = http.lastStatus
            guard status == 403 || (error as? GrokSTTError) == .forbidden else {
                throw XCTSkip(
                    "L7 blocked/unrun: POST /v1/stt returned \(status.map(String.init) ?? String(describing: error)) instead of 403. No-retry is unit-covered by test403DoesNotRetry; this skip is not L7 coverage."
                )
            }
            XCTAssertEqual(error as? GrokSTTError, .forbidden)
            XCTAssertEqual(status, 403)
            XCTAssertEqual(http.requestCount, 1, "403 must not retry")
            XCTAssertEqual(resolver.unauthorizedCallCount, 0, "403 must not consult a CLI alternate")
        }
    }

    func testL12FilipinoLanguageCodeIsAccepted() async throws {
        try Self.requireLive()
        let resolver: any GrokSTTCredentialResolving
        if let key = try? GrokSTTKeychain.shared.loadAPIKey(), !key.isEmpty {
            resolver = RecordingGrokSTTResolver(source: .apiKey, bearer: key)
        } else {
            let cli = try Self.cliResolver()
            guard cli.isSourceConfigured else {
                throw XCTSkip("No STT credential source for L12")
            }
            resolver = cli
        }
        let client = GrokSTTRESTClient(resolver: resolver, http: GrokSTTURLSessionHTTPClient())
        let samples = try Self.fixtureSamples()
        let result = try await client.transcribePCM(samples, languageCode: "fil")
        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// L13: GUI-less / Finder launch has no shell PATH. The production locator must
    /// still find `~/.grok/bin/grok` (or another known absolute path) or show the
    /// instruction. Does not spawn `grok`.
    func testL13GUILessBinaryLocatorWithoutPATH() throws {
        try Self.requireLive()
        let locator = GrokCLIBinaryLocator(
            fileSystem: GrokSTTFoundationFileSystem(),
            homeDirectory: { FileManager.default.homeDirectoryForCurrentUser },
            userOverride: { nil }
        )
        let homeGrok = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/bin/grok").path
        let allowed = [
            homeGrok,
            "/opt/homebrew/bin/grok",
            "/usr/local/bin/grok",
        ]
        do {
            let url = try locator.locate()
            XCTAssertTrue((url.path as NSString).isAbsolutePath, "locator must never return a bare grok")
            XCTAssertTrue(
                allowed.contains(url.path),
                "locator must use a known absolute path, got \(url.path)"
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/test")
            process.arguments = ["-x", url.path]
            process.environment = ["PATH": ""]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "located grok must be executable with PATH empty")
        } catch let error as GrokSTTError {
            XCTAssertEqual(error, .grokCLINotFound)
            XCTAssertEqual(
                error.errorDescription,
                "Open Grok Build once (or set the grok CLI path in Voice Engine settings) so FluidVoice can refresh your session."
            )
        }
    }

    private static func requireLive() throws {
        guard ProcessInfo.processInfo.environment["GROK_STT_LIVE"] == "1" else {
            throw XCTSkip("Set GROK_STT_LIVE=1 to run authorized Grok STT probes")
        }
    }

    private static func requireSTTAPIKey() throws -> String {
        // STT Keychain only. Never read com.fluidvoice.provider-api-keys / "xai".
        XCTAssertEqual(GrokSTTKeychain.service, "com.fluidvoice.stt-credentials")
        guard let key = try GrokSTTKeychain.shared.loadAPIKey(), !key.isEmpty else {
            throw XCTSkip("No xAI STT API key in com.fluidvoice.stt-credentials")
        }
        return key
    }

    private static func cliResolver() throws -> GrokSTTCredentialResolver {
        var dependencies = GrokSTTCredentialResolverDependencies.production()
        dependencies.authMode = { .grokCLISession }
        return GrokSTTCredentialResolver(dependencies: dependencies)
    }

    private static func fixtureSamples() throws -> [Float] {
        let bundle = Bundle(for: GrokSTTLiveProbeTests.self)
        guard let url = bundle.url(forResource: "dictation_fixture", withExtension: "wav") else {
            throw XCTSkip("dictation_fixture.wav is not in the test bundle")
        }
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 44)
        return try Self.float32FromWAV(data)
    }

    private static func float32FromWAV(_ data: Data) throws -> [Float] {
        guard data.count > 44 else { throw GrokSTTError.invalidAudio }
        let pcm = data.dropFirst(44)
        let count = pcm.count / 2
        var samples = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                samples[i] = Float(Int16(littleEndian: ints[i])) / Float(Int16.max)
            }
        }
        return samples
    }

    /// L1 empty-audio half: HTTP 4xx. 200 + empty transcript, 5xx, and 401 are not 4xx-for-empty-audio.
    private static func assertEmptyAudio4xx(
        status: Int?,
        error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let status else {
            XCTFail("L1 empty audio produced no HTTP status (error: \(error))", file: file, line: line)
            return
        }
        XCTAssertNotEqual(
            error as? GrokSTTError,
            .emptyTranscript,
            "L1 empty audio requires HTTP 4xx, not 200 + empty transcript",
            file: file,
            line: line
        )
        XCTAssertNotEqual(
            status,
            401,
            "L1 empty audio with a working API key must not be 401 (got \(error))",
            file: file,
            line: line
        )
        XCTAssertTrue(
            (400..<500).contains(status),
            "L1 empty audio requires HTTP 4xx, got \(status) error=\(error)",
            file: file,
            line: line
        )
    }
}

/// Captures live HTTP status codes so L1/L7 can assert the wire status, not a mapped error.
private final class CountingGrokSTTHTTPClient: GrokSTTHTTPPerforming, @unchecked Sendable {
    private let inner: any GrokSTTHTTPPerforming
    private let lock = NSLock()
    private var statuses: [Int] = []

    init(inner: any GrokSTTHTTPPerforming) {
        self.inner = inner
    }

    var requestCount: Int {
        self.lock.withLock { self.statuses.count }
    }

    var lastStatus: Int? {
        self.lock.withLock { self.statuses.last }
    }

    func reset() {
        self.lock.withLock { self.statuses = [] }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await self.inner.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        self.lock.withLock { self.statuses.append(status) }
        return (data, response)
    }
}
