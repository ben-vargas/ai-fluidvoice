@testable import FluidVoice_Debug
import XCTest

/// Opt-in live probes (L1, L3, L6, L7, L12). Never run in CI.
/// Set `GROK_STT_LIVE=1`. Does not reuse LLM Keychain `com.fluidvoice.provider-api-keys`.
#if !os(iOS)
final class GrokSTTLiveProbeTests: XCTestCase {
    func testL1APIKeyRESTPCMAndEmptyAudio() async throws {
        try Self.requireLive()
        let key = try Self.requireSTTAPIKey()
        let resolver = RecordingGrokSTTResolver(source: .apiKey, bearer: key)
        let client = GrokSTTRESTClient(resolver: resolver, http: GrokSTTURLSessionHTTPClient())
        let samples = try Self.fixtureSamples()
        let result = try await client.transcribePCM(samples, languageCode: nil)
        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
        } catch let error as GrokSTTError {
            switch error {
            case .invalidAudio, .emptyTranscript, .server, .unauthorized:
                break
            default:
                let code = error.numericCode
                XCTAssertTrue((1400..<1500).contains(code) || code == 1601 || code == 1603, "expected 4xx-class, got \(error)")
            }
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

    func testL7ForbiddenDoesNotRetry() async throws {
        try Self.requireLive()
        throw XCTSkip("xAI 403 is not reliably inducible; no-retry is locked by test403DoesNotRetry (L7)")
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
}

#endif
