@testable import FluidVoice_Debug
import XCTest

final class GrokSTTCredentialResolverTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let authPath = "/Users/test/.grok/auth.json"

    func testAPIKeyModeNeverReadsCLIStore() async throws {
        let files = MemoryGrokSTTFileSystem()
        files.explodeOnRead = true
        let apiKeys = InMemoryGrokSTTAPIKeyStore(key: "xai-stt-test-key")
        let resolver = self.makeResolver(
            mode: .apiKey,
            apiKeys: apiKeys,
            files: files,
            refresh: CountingGrokCLIRefresh()
        )
        let credential = try await resolver.resolveCredential()
        XCTAssertEqual(credential.source, .apiKey)
        XCTAssertEqual(credential.bearer, "xai-stt-test-key")
        XCTAssertNil(credential.expiresAt)
    }

    func testCLIModeDoesNotFallBackToAPIKey() async {
        let files = MemoryGrokSTTFileSystem()
        let apiKeys = InMemoryGrokSTTAPIKeyStore(key: "xai-stt-test-key")
        let resolver = self.makeResolver(
            mode: .grokCLISession,
            apiKeys: apiKeys,
            files: files,
            refresh: CountingGrokCLIRefresh()
        )
        do {
            _ = try await resolver.resolveCredential()
            XCTFail("CLI mode must not silently use the API key")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .noCredentialConfigured)
        }
    }

    func testAPIKeyMode401RecoveryDoesNotSwitchToCLI() async {
        let files = MemoryGrokSTTFileSystem()
        files.files[self.authPath] = self.sessionJSON(key: "cli-bearer", expiresFromNow: 3600)
        let apiKeys = InMemoryGrokSTTAPIKeyStore(key: "xai-stt-test-key")
        let resolver = self.makeResolver(
            mode: .apiKey,
            apiKeys: apiKeys,
            files: files,
            refresh: CountingGrokCLIRefresh()
        )
        do {
            _ = try await resolver.resolveCredentialAfterUnauthorized(
                rejectedBearerFingerprint: GrokSTTCredential.fingerprint("xai-stt-test-key")
            )
            XCTFail("API key mode must not recover via CLI")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .unauthorized)
        }
    }

    func testUnauthorizedPicksOneAlternateAndNeverRefreshes() async throws {
        let files = MemoryGrokSTTFileSystem()
        files.files[self.authPath] = self.twoSessionJSON()
        let refresh = CountingGrokCLIRefresh()
        let resolver = self.makeResolver(
            mode: .grokCLISession,
            apiKeys: InMemoryGrokSTTAPIKeyStore(),
            files: files,
            refresh: refresh
        )
        let credential = try await resolver.resolveCredentialAfterUnauthorized(
            rejectedBearerFingerprint: GrokSTTCredential.fingerprint("first-bearer")
        )
        XCTAssertEqual(credential.source, .grokCLISession)
        XCTAssertEqual(credential.bearer, "second-bearer")
        XCTAssertEqual(refresh.spawnCount, 0)
    }

    func testUnauthorizedRecoveryPicksUnexpiredAlternateOverExpiredSelfConsistent() async throws {
        let files = MemoryGrokSTTFileSystem()
        files.files[self.authPath] = self.rejectedExpiredConsistentAndLiveMismatchedJSON()
        let refresh = CountingGrokCLIRefresh()
        let resolver = self.makeResolver(
            mode: .grokCLISession,
            apiKeys: InMemoryGrokSTTAPIKeyStore(),
            files: files,
            refresh: refresh
        )
        let credential = try await resolver.resolveCredentialAfterUnauthorized(
            rejectedBearerFingerprint: GrokSTTCredential.fingerprint("rejected-bearer")
        )
        XCTAssertEqual(credential.source, .grokCLISession)
        XCTAssertEqual(credential.bearer, "live-mismatch")
        XCTAssertEqual(refresh.spawnCount, 0)
    }

    func testRefreshIsSingleFlightAndNeverTerminates() async throws {
        let files = MemoryGrokSTTFileSystem()
        files.files[self.authPath] = self.sessionJSON(key: "expired-bearer", expiresFromNow: 100)
        files.executables.insert("/Users/test/.grok/bin/grok")
        let refresh = CountingGrokCLIRefresh()
        refresh.delay = 0.25
        refresh.onRefresh = { files.files[self.authPath] = self.sessionJSON(key: "fresh-bearer", expiresFromNow: 3600) }
        let resolver = self.makeResolver(
            mode: .grokCLISession,
            apiKeys: InMemoryGrokSTTAPIKeyStore(),
            files: files,
            refresh: refresh,
            refreshWaitBudget: 2
        )

        async let first = resolver.resolveCredential()
        async let second = resolver.resolveCredential()
        let credentials = try await [first, second]
        XCTAssertEqual(Set(credentials.map(\.bearer)), ["fresh-bearer"])
        XCTAssertEqual(refresh.spawnCount, 1)
        XCTAssertFalse(refresh.terminateCalled)
    }

    func testRefreshTimeoutLeavesChildRunning() async {
        let files = MemoryGrokSTTFileSystem()
        files.files[self.authPath] = self.sessionJSON(key: "expired-bearer", expiresFromNow: 100)
        files.executables.insert("/Users/test/.grok/bin/grok")
        let refresh = CountingGrokCLIRefresh()
        refresh.delay = 2
        let resolver = self.makeResolver(
            mode: .grokCLISession,
            apiKeys: InMemoryGrokSTTAPIKeyStore(),
            files: files,
            refresh: refresh,
            refreshWaitBudget: 0.05
        )
        do {
            _ = try await resolver.resolveCredential()
            XCTFail("Expected refreshInProgress")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .refreshInProgress)
        }
        XCTAssertEqual(refresh.spawnCount, 1)
        XCTAssertTrue(refresh.isRunning)
        XCTAssertFalse(refresh.terminateCalled)
    }

    func testIsSourceConfiguredWithExpiredStoreOrAPIKey() {
        let files = MemoryGrokSTTFileSystem()
        files.files[self.authPath] = self.sessionJSON(key: "expired-bearer", expiresFromNow: 100)
        let withStore = self.makeResolver(
            mode: .grokCLISession,
            apiKeys: InMemoryGrokSTTAPIKeyStore(),
            files: files,
            refresh: CountingGrokCLIRefresh()
        )
        XCTAssertTrue(withStore.isSourceConfigured)

        let withKey = self.makeResolver(
            mode: .apiKey,
            apiKeys: InMemoryGrokSTTAPIKeyStore(key: "xai-stt-test-key"),
            files: MemoryGrokSTTFileSystem(),
            refresh: CountingGrokCLIRefresh()
        )
        XCTAssertTrue(withKey.isSourceConfigured)

        let neither = self.makeResolver(
            mode: .apiKey,
            apiKeys: InMemoryGrokSTTAPIKeyStore(),
            files: MemoryGrokSTTFileSystem(),
            refresh: CountingGrokCLIRefresh()
        )
        XCTAssertFalse(neither.isSourceConfigured)
    }

    func testIsSourceConfiguredIgnoresTheOtherMode() {
        let files = MemoryGrokSTTFileSystem()
        files.files[self.authPath] = self.sessionJSON(key: "cli-bearer", expiresFromNow: 3600)

        let apiKeyModeStoreOnly = self.makeResolver(
            mode: .apiKey,
            apiKeys: InMemoryGrokSTTAPIKeyStore(),
            files: files,
            refresh: CountingGrokCLIRefresh()
        )
        XCTAssertFalse(apiKeyModeStoreOnly.isSourceConfigured)

        let cliModeKeyOnly = self.makeResolver(
            mode: .grokCLISession,
            apiKeys: InMemoryGrokSTTAPIKeyStore(key: "xai-stt-test-key"),
            files: MemoryGrokSTTFileSystem(),
            refresh: CountingGrokCLIRefresh()
        )
        XCTAssertFalse(cliModeKeyOnly.isSourceConfigured)
    }

    func testExpiredSelfConsistentTriggersRefreshInsteadOfMismatchedLiveEntry() async throws {
        let files = MemoryGrokSTTFileSystem()
        files.files[self.authPath] = self.expiredConsistentAndLiveMismatchedJSON()
        files.executables.insert("/Users/test/.grok/bin/grok")
        let refresh = CountingGrokCLIRefresh()
        refresh.onRefresh = {
            files.files[self.authPath] = self.sessionJSON(key: "fresh-consistent", expiresFromNow: 3600)
        }
        let resolver = self.makeResolver(
            mode: .grokCLISession,
            apiKeys: InMemoryGrokSTTAPIKeyStore(),
            files: files,
            refresh: refresh
        )
        let credential = try await resolver.resolveCredential()
        XCTAssertEqual(credential.bearer, "fresh-consistent")
        XCTAssertEqual(credential.source, .grokCLISession)
        XCTAssertEqual(refresh.spawnCount, 1)
    }

    func testRefreshSpawnsSessionsListOnly() async throws {
        let spy = SpyGrokCLIProcessLauncher()
        let delegate = GrokCLIRefreshDelegate(launcher: spy)
        try await delegate.refreshSession(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            authPath: "/tmp/auth.json",
            environment: ["PATH": "/usr/bin"]
        )
        XCTAssertEqual(spy.requests.count, 1)
        XCTAssertEqual(spy.requests[0].arguments, ["sessions", "list", "-n", "1"])
        XCTAssertEqual(spy.requests[0].environment["GROK_AUTH_PATH"], "/tmp/auth.json")
        XCTAssertTrue(spy.requests[0].executable.path.hasPrefix("/"))
        XCTAssertNotEqual(spy.requests[0].executable.path, "grok")
        XCTAssertFalse(spy.terminateCalled)
    }

    func testErrorsRedactTokensAndRestrictUserInfo() {
        let cases: [GrokSTTError] = [
            .noCredentialConfigured,
            .grokCLINotFound,
            .grokStoreUnreadable,
            .grokStoreParseFailed,
            .grokSessionExpired,
            .refreshInProgress,
            .unauthorized,
            .forbidden,
            .rateLimited(retryAfter: 2),
            .timeout,
            .offline,
            .server(status: 401, message: "Bearer supersecret-token-value-12345678901234567890"),
            .socketClosed(code: 1006),
            .emptyTranscript,
            .cancelled,
            .invalidAudio,
            .fileTooLarge,
            .unsupportedFile,
            .dictionaryTrainingUnsupported,
            .videoUploadForbidden,
        ]
        for error in cases {
            let nsError = error.asNSError()
            XCTAssertEqual(Array(nsError.userInfo.keys), [NSLocalizedDescriptionKey])
            let texts = [
                nsError.localizedDescription,
                String(describing: error),
                String(reflecting: error),
            ]
            for text in texts {
                XCTAssertFalse(text.localizedCaseInsensitiveContains("Bearer"), text)
                XCTAssertFalse(text.contains("supersecret-token-value"), text)
                XCTAssertFalse(text.localizedCaseInsensitiveContains("refresh_token"), text)
            }
            XCTAssertEqual(nsError.domain, GrokSTTError.nsErrorDomain)
            XCTAssertEqual(nsError.code, error.numericCode)
            if case let .server(_, stored) = error {
                XCTAssertFalse(stored.value.localizedCaseInsensitiveContains("Bearer"), stored.value)
                XCTAssertFalse(stored.value.contains("supersecret-token-value"), stored.value)
            }
        }

        let credentialPayloads: [String] = [
            "Bearer supersecret-token-value-12345678901234567890",
            #""key": "sk-live-secret-value""#,
            "Cookie: session=abc123; auth=xyz-credential",
            #"{"https://auth.x.ai::client-a":{"key":"cli-store-secret","oidc_issuer":"https://auth.x.ai","oidc_client_id":"client-a"}}"#,
        ]
        for payload in credentialPayloads {
            self.assertServerPayloadRedacted(
                GrokSTTError.server(status: 503, message: GrokSTTSanitizedMessage(payload)),
                secrets: [
                    "Bearer",
                    "supersecret-token-value",
                    "sk-live-secret-value",
                    "session=abc123",
                    "cli-store-secret",
                    "oidc_issuer",
                ]
            )
            self.assertServerPayloadRedacted(
                GrokSTTError.fromHTTPStatus(503, message: payload),
                secrets: [
                    "Bearer",
                    "supersecret-token-value",
                    "sk-live-secret-value",
                    "session=abc123",
                    "cli-store-secret",
                    "oidc_issuer",
                ]
            )
        }
    }

    private func assertServerPayloadRedacted(_ error: GrokSTTError, secrets: [String]) {
        guard case let .server(_, stored) = error else {
            return XCTFail("expected .server, got \(error)")
        }
        let surfaces = [
            stored.value,
            String(describing: stored),
            String(reflecting: stored),
            String(describing: error),
            String(reflecting: error),
            error.asNSError().localizedDescription,
        ]
        for text in surfaces {
            for needle in secrets {
                XCTAssertFalse(
                    text.localizedCaseInsensitiveContains(needle),
                    "payload leaked \(needle) via \(text)"
                )
            }
        }
    }

    func testForbiddenHasNoRetryHelper() {
        XCTAssertEqual(GrokSTTError.fromHTTPStatus(403), .forbidden)
        XCTAssertEqual(GrokSTTError.fromHTTPStatus(401), .unauthorized)
        XCTAssertEqual(GrokSTTError.fromHTTPStatus(429, retryAfter: 5), .rateLimited(retryAfter: 5))
    }

    private func makeResolver(
        mode: GrokSTTAuthMode,
        apiKeys: InMemoryGrokSTTAPIKeyStore,
        files: MemoryGrokSTTFileSystem,
        refresh: CountingGrokCLIRefresh,
        refreshWaitBudget: TimeInterval = 8
    ) -> GrokSTTCredentialResolver {
        let environment = ["HOME": self.home.path]
        let store = GrokCLIAuthStore(
            fileSystem: files,
            environment: { environment },
            homeDirectory: { self.home },
            now: { self.now }
        )
        let locator = GrokCLIBinaryLocator(
            fileSystem: files,
            homeDirectory: { self.home },
            userOverride: { nil }
        )
        return GrokSTTCredentialResolver(
            dependencies: GrokSTTCredentialResolverDependencies(
                authMode: { mode },
                apiKeyStore: apiKeys,
                authStore: store,
                binaryLocator: locator,
                refresh: refresh,
                refreshWaitBudget: refreshWaitBudget,
                processEnvironment: { environment }
            )
        )
    }

    private func sessionJSON(key: String, expiresFromNow: TimeInterval) -> Data {
        let expires = ISO8601DateFormatter().string(from: self.now.addingTimeInterval(expiresFromNow))
        let json = """
        {
          "https://auth.x.ai::client-a": {
            "key": "\(key)",
            "expires_at": "\(expires)",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "client-a",
            "email": "user@example.com"
          }
        }
        """
        return Data(json.utf8)
    }

    private func rejectedExpiredConsistentAndLiveMismatchedJSON() -> Data {
        let expired = ISO8601DateFormatter().string(from: self.now.addingTimeInterval(100))
        let live = ISO8601DateFormatter().string(from: self.now.addingTimeInterval(3600))
        let json = """
        {
          "https://auth.x.ai::rejected": {
            "key": "rejected-bearer",
            "expires_at": "\(live)",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "rejected"
          },
          "https://auth.x.ai::client-a": {
            "key": "expired-consistent",
            "expires_at": "\(expired)",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "client-a"
          },
          "mismatch-scope": {
            "key": "live-mismatch",
            "expires_at": "\(live)",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "client-b"
          }
        }
        """
        return Data(json.utf8)
    }

    private func expiredConsistentAndLiveMismatchedJSON() -> Data {
        let expired = ISO8601DateFormatter().string(from: self.now.addingTimeInterval(100))
        let live = ISO8601DateFormatter().string(from: self.now.addingTimeInterval(3600))
        let json = """
        {
          "https://auth.x.ai::client-a": {
            "key": "expired-consistent",
            "expires_at": "\(expired)",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "client-a"
          },
          "mismatch-scope": {
            "key": "live-mismatch",
            "expires_at": "\(live)",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "client-b"
          }
        }
        """
        return Data(json.utf8)
    }

    private func twoSessionJSON() -> Data {
        let expires = ISO8601DateFormatter().string(from: self.now.addingTimeInterval(3600))
        let json = """
        {
          "https://auth.x.ai::client-a": {
            "key": "first-bearer",
            "expires_at": "\(expires)",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "client-a"
          },
          "https://auth.x.ai::client-b": {
            "key": "second-bearer",
            "expires_at": "\(expires)",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "client-b"
          }
        }
        """
        return Data(json.utf8)
    }
}

final class InMemoryGrokSTTAPIKeyStore: GrokSTTAPIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    init(key: String? = nil) {
        self.key = key
    }

    func loadAPIKey() throws -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.key
    }

    func storeAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lock.lock()
        defer { self.lock.unlock() }
        self.key = trimmed.isEmpty ? nil : trimmed
    }

    func deleteAPIKey() throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.key = nil
    }
}

final class CountingGrokCLIRefresh: GrokCLIRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var spawnCount = 0
    private(set) var isRunning = false
    private(set) var terminateCalled = false
    var delay: TimeInterval = 0
    var onRefresh: (() -> Void)?

    func refreshSession(executable: URL, authPath: String, environment: [String: String]) async throws {
        _ = authPath
        _ = environment
        XCTAssertTrue(executable.path.hasPrefix("/"))
        XCTAssertNotEqual(executable.path, "grok")
        self.lock.lock()
        self.spawnCount += 1
        self.isRunning = true
        self.lock.unlock()
        if self.delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(self.delay * 1_000_000_000))
        }
        self.onRefresh?()
        self.lock.lock()
        self.isRunning = false
        self.lock.unlock()
    }
}

final class SpyGrokCLIProcessLauncher: GrokCLIProcessLaunching, @unchecked Sendable {
    var requests: [GrokCLIProcessRequest] = []
    var terminateCalled = false

    func launch(_ request: GrokCLIProcessRequest) throws -> any GrokCLILaunchedProcess {
        self.requests.append(request)
        return ImmediateGrokCLIProcess()
    }
}

private struct ImmediateGrokCLIProcess: GrokCLILaunchedProcess {
    var isRunning: Bool {
        false
    }

    func waitUntilExit() async {}
}
