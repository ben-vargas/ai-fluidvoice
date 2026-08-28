@testable import FluidVoice_Debug
import XCTest

final class GrokSTTCLIAuthStoreTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDefinedEmptyGrokAuthPathIsLiteralEmpty() {
        let store = self.makeStore(environment: ["GROK_AUTH_PATH": ""])
        XCTAssertEqual(store.resolvePath(), "")
    }

    func testEmptyGrokHomeFallsBackToDefaultAuthJSON() {
        let store = self.makeStore(environment: ["GROK_HOME": ""])
        XCTAssertEqual(store.resolvePath(), "/Users/test/.grok/auth.json")
    }

    func testDefaultPathIsHomeGrokAuthJSON() {
        let store = self.makeStore(environment: [:])
        XCTAssertEqual(store.resolvePath(), "/Users/test/.grok/auth.json")
    }

    func testGrokHomeJoinsAuthJSON() {
        let store = self.makeStore(environment: ["GROK_HOME": "/custom/grok"])
        XCTAssertEqual(store.resolvePath(), "/custom/grok/auth.json")
    }

    func testDefinedGrokAuthPathWinsEvenWhenGrokHomeIsSet() {
        let store = self.makeStore(environment: [
            "GROK_AUTH_PATH": "/tmp/custom-auth.json",
            "GROK_HOME": "/custom/grok",
        ])
        XCTAssertEqual(store.resolvePath(), "/tmp/custom-auth.json")
    }

    func testRotatedUnexpiredWinsScoring() throws {
        let previous = ["https://auth.x.ai::client-a": "old-key"]
        let rotated = self.loaded(
            scope: "https://auth.x.ai::client-a",
            key: "new-key",
            expiresAt: self.now.addingTimeInterval(3600),
            issuer: "https://auth.x.ai",
            client: "client-a"
        )
        let other = self.loaded(
            scope: "https://auth.x.ai::client-b",
            key: "other-key",
            expiresAt: self.now.addingTimeInterval(3600),
            issuer: "https://auth.x.ai",
            client: "client-b"
        )
        let picked = try XCTUnwrap(self.makeStore().pick(
            from: [other, rotated],
            previousKeys: previous,
            exclude: nil
        ))
        XCTAssertEqual(picked.entry.key, "new-key")
    }

    func testSelfConsistentBeatsUnexpiredOther() throws {
        let consistent = self.loaded(
            scope: "https://auth.x.ai::client-a",
            key: "consistent",
            expiresAt: self.now.addingTimeInterval(3600),
            issuer: "https://auth.x.ai",
            client: "client-a"
        )
        let other = self.loaded(
            scope: "mismatch-scope",
            key: "other",
            expiresAt: self.now.addingTimeInterval(3600),
            issuer: "https://auth.x.ai",
            client: "client-b"
        )
        let picked = try XCTUnwrap(self.makeStore().pick(
            from: [other, consistent],
            previousKeys: [:],
            exclude: nil
        ))
        XCTAssertEqual(picked.entry.key, "consistent")
    }

    func testExpiredNeverPreferredOverUnexpired() throws {
        let expiredConsistent = self.loaded(
            scope: "https://auth.x.ai::client-a",
            key: "expired",
            expiresAt: self.now.addingTimeInterval(100),
            issuer: "https://auth.x.ai",
            client: "client-a"
        )
        XCTAssertTrue(expiredConsistent.isExpired)
        let unexpiredOther = self.loaded(
            scope: "mismatch-scope",
            key: "live",
            expiresAt: self.now.addingTimeInterval(3600),
            issuer: "https://auth.x.ai",
            client: "client-b"
        )
        let picked = try XCTUnwrap(self.makeStore().pick(
            from: [expiredConsistent, unexpiredOther],
            previousKeys: [:],
            exclude: nil
        ))
        XCTAssertEqual(picked.entry.key, "live")
    }

    func testPickExcludesRejectedKey() throws {
        let first = self.loaded(
            scope: "https://auth.x.ai::client-a",
            key: "rejected-bearer",
            expiresAt: self.now.addingTimeInterval(3600),
            issuer: "https://auth.x.ai",
            client: "client-a"
        )
        let second = self.loaded(
            scope: "https://auth.x.ai::client-b",
            key: "alternate-bearer",
            expiresAt: self.now.addingTimeInterval(3600),
            issuer: "https://auth.x.ai",
            client: "client-b"
        )
        let picked = try XCTUnwrap(self.makeStore().pick(
            from: [first, second],
            previousKeys: [:],
            exclude: GrokSTTCredential.fingerprint("rejected-bearer")
        ))
        XCTAssertEqual(picked.entry.key, "alternate-bearer")
    }

    func testEntryExpiringIn299SecondsIsExpired() {
        let entry = self.loaded(
            scope: "https://auth.x.ai::client-a",
            key: "soon",
            expiresAt: self.now.addingTimeInterval(299),
            issuer: "https://auth.x.ai",
            client: "client-a"
        )
        XCTAssertTrue(entry.isExpired)
        XCTAssertTrue(GrokCLIAuthStore.isExpired(self.now.addingTimeInterval(300), now: self.now))
        XCTAssertFalse(GrokCLIAuthStore.isExpired(self.now.addingTimeInterval(301), now: self.now))
    }

    func testParserHasNoRefreshTokenCodingKey() {
        let keys = GrokCLIAuthEntry.CodingKeys.allCases.map(\.rawValue)
        XCTAssertFalse(keys.contains("refresh_token"))
        XCTAssertEqual(keys, ["key", "expires_at", "oidc_issuer", "oidc_client_id", "email"])
    }

    func testParserSkipsMissingKeyAndIgnoresRefreshToken() throws {
        let json = """
        {
          "https://auth.x.ai::missing": {
            "expires_at": "2099-01-01T00:00:00Z",
            "refresh_token": "must-not-be-decoded",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "missing"
          },
          "https://auth.x.ai::kept": {
            "key": "kept-key",
            "expires_at": "2099-01-01T00:00:00Z",
            "refresh_token": "also-ignored",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "kept",
            "email": "kept@example.com"
          }
        }
        """
        let entries = try self.makeStore().decodeEntries(from: Data(json.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].entry.key, "kept-key")
        XCTAssertEqual(entries[0].entry.email, "kept@example.com")
    }

    func testOversizeStoreFails() {
        let files = MemoryGrokSTTFileSystem()
        let path = "/Users/test/.grok/auth.json"
        files.files[path] = Data(repeating: 0x61, count: GrokCLIAuthStore.maxFileBytes + 1)
        let store = self.makeStore(fileSystem: files)
        XCTAssertThrowsError(try store.loadEntries()) { error in
            XCTAssertEqual(error as? GrokSTTError, .grokStoreParseFailed)
        }
    }

    func testTieKeepsFileOrder() throws {
        let json = """
        {
          "https://auth.x.ai::first": {
            "key": "first-key",
            "expires_at": "2099-01-01T00:00:00Z",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "first"
          },
          "https://auth.x.ai::second": {
            "key": "second-key",
            "expires_at": "2099-01-01T00:00:00Z",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "second"
          }
        }
        """
        let store = self.makeStore()
        let entries = try store.decodeEntries(from: Data(json.utf8))
        let picked = try XCTUnwrap(store.pick(from: entries, previousKeys: [:], exclude: nil))
        XCTAssertEqual(picked.entry.key, "first-key")
    }

    func testBinaryLocatorDoesNotUseBareGrokAndHonorsOverride() throws {
        let files = MemoryGrokSTTFileSystem()
        files.executables.insert("/opt/custom/bin/grok")
        files.executables.insert("/Users/test/.grok/bin/grok")
        let locator = GrokCLIBinaryLocator(
            fileSystem: files,
            homeDirectory: { self.home },
            userOverride: { "grok" }
        )
        XCTAssertEqual(try locator.locate().path, "/Users/test/.grok/bin/grok")

        let overrideLocator = GrokCLIBinaryLocator(
            fileSystem: files,
            homeDirectory: { self.home },
            userOverride: { "/opt/custom/bin/grok" }
        )
        XCTAssertEqual(try overrideLocator.locate().path, "/opt/custom/bin/grok")
    }

    func testBinaryLocatorSearchesKnownPaths() throws {
        let files = MemoryGrokSTTFileSystem()
        files.executables.insert("/usr/local/bin/grok")
        let locator = GrokCLIBinaryLocator(
            fileSystem: files,
            homeDirectory: { self.home },
            userOverride: { nil }
        )
        XCTAssertEqual(try locator.locate().path, "/usr/local/bin/grok")
    }

    func testBinaryLocatorThrowsWhenMissing() {
        let locator = GrokCLIBinaryLocator(
            fileSystem: MemoryGrokSTTFileSystem(),
            homeDirectory: { self.home },
            userOverride: { "grok" }
        )
        XCTAssertThrowsError(try locator.locate()) { error in
            XCTAssertEqual(error as? GrokSTTError, .grokCLINotFound)
            XCTAssertEqual(
                (error as? GrokSTTError)?.errorDescription,
                "Open Grok Build once (or set the grok CLI path in Voice Engine settings) so FluidVoice can refresh your session."
            )
        }
    }

    private func makeStore(
        fileSystem: MemoryGrokSTTFileSystem = MemoryGrokSTTFileSystem(),
        environment: [String: String] = [:]
    ) -> GrokCLIAuthStore {
        GrokCLIAuthStore(
            fileSystem: fileSystem,
            environment: { environment },
            homeDirectory: { self.home },
            now: { self.now }
        )
    }

    private func loaded(
        scope: String,
        key: String,
        expiresAt: Date?,
        issuer: String?,
        client: String?
    ) -> GrokCLIAuthLoadedEntry {
        let entry = GrokCLIAuthEntry(
            key: key,
            expires_at: expiresAt.map { ISO8601DateFormatter().string(from: $0) },
            oidc_issuer: issuer,
            oidc_client_id: client,
            email: nil
        )
        return GrokCLIAuthLoadedEntry(
            scopeKey: scope,
            entry: entry,
            expiresAt: expiresAt,
            isExpired: GrokCLIAuthStore.isExpired(expiresAt, now: self.now),
            isSelfConsistent: scope == "\(issuer ?? "")::\(client ?? "")"
        )
    }
}

final class MemoryGrokSTTFileSystem: GrokSTTFileReading, @unchecked Sendable {
    var files: [String: Data] = [:]
    var executables: Set<String> = []
    var explodeOnRead = false

    func fileExists(at url: URL) -> Bool {
        if self.explodeOnRead {
            XCTFail("CLI store should not be read")
        }
        return self.files[url.path] != nil
    }

    func isExecutableFile(at url: URL) -> Bool {
        self.executables.contains(url.path)
    }

    func contents(at url: URL) throws -> Data {
        if self.explodeOnRead {
            XCTFail("CLI store should not be read")
            throw GrokSTTError.grokStoreUnreadable
        }
        guard let data = self.files[url.path] else {
            throw GrokSTTError.grokStoreUnreadable
        }
        return data
    }

    func byteCount(at url: URL) throws -> Int {
        if self.explodeOnRead {
            XCTFail("CLI store should not be read")
            throw GrokSTTError.grokStoreUnreadable
        }
        guard let data = self.files[url.path] else {
            throw GrokSTTError.grokStoreUnreadable
        }
        return data.count
    }
}
