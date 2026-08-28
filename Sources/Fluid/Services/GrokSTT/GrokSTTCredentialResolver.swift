import Foundation

nonisolated struct GrokSTTCredentialResolverDependencies: Sendable {
    var authMode: @Sendable () -> GrokSTTAuthMode
    var apiKeyStore: any GrokSTTAPIKeyStoring
    var authStore: GrokCLIAuthStore
    var binaryLocator: any GrokCLIBinaryLocating
    var refresh: any GrokCLIRefreshing
    var refreshWaitBudget: TimeInterval
    var processEnvironment: @Sendable () -> [String: String]

    static func production() -> GrokSTTCredentialResolverDependencies {
        let fileSystem = GrokSTTFoundationFileSystem()
        let environment: @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
        let homeDirectory: @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
        let now: @Sendable () -> Date = Date.init
        return GrokSTTCredentialResolverDependencies(
            authMode: {
                SettingsStore.grokSTTAuthMode(fromStoredValue: UserDefaults.standard.string(
                    forKey: SettingsStore.grokSTTAuthModeDefaultsKey
                ))
            },
            apiKeyStore: GrokSTTKeychain.shared,
            authStore: GrokCLIAuthStore(
                fileSystem: fileSystem,
                environment: environment,
                homeDirectory: homeDirectory,
                now: now
            ),
            binaryLocator: GrokCLIBinaryLocator(
                fileSystem: fileSystem,
                homeDirectory: homeDirectory,
                userOverride: {
                    UserDefaults.standard.string(forKey: SettingsStore.grokCLIBinaryPathDefaultsKey)
                }
            ),
            refresh: GrokCLIRefreshDelegate(),
            refreshWaitBudget: 8,
            processEnvironment: environment
        )
    }
}

/// v1 credential resolver. Explicit auth mode: API key XOR Grok CLI session. Errors never switch billing modes.
final nonisolated class GrokSTTCredentialResolver: GrokSTTCredentialResolving, @unchecked Sendable {
    static let shared = GrokSTTCredentialResolver()

    private let dependencies: GrokSTTCredentialResolverDependencies
    private let lock = NSLock()
    private var inFlightRefresh: Task<Void, Error>?
    private var inFlightRefreshID: UUID?

    init(dependencies: GrokSTTCredentialResolverDependencies = .production()) {
        self.dependencies = dependencies
    }

    var isSourceConfigured: Bool {
        switch self.dependencies.authMode() {
        case .apiKey:
            return self.dependencies.apiKeyStore.hasAPIKey
        case .grokCLISession:
            return self.dependencies.authStore.hasReadableKey()
        }
    }

    func resolveCredential() async throws -> GrokSTTCredential {
        switch self.dependencies.authMode() {
        case .apiKey:
            return try self.resolveAPIKey()
        case .grokCLISession:
            return try await self.resolveCLISession(allowRefresh: true)
        }
    }

    func resolveCredentialAfterUnauthorized(rejectedBearerFingerprint: String) async throws -> GrokSTTCredential {
        guard self.dependencies.authMode() == .grokCLISession else {
            throw GrokSTTError.unauthorized
        }
        return try await self.resolveCLISession(
            allowRefresh: false,
            exclude: rejectedBearerFingerprint
        )
    }

    private func resolveAPIKey() throws -> GrokSTTCredential {
        guard let key = try self.dependencies.apiKeyStore.loadAPIKey(), !key.isEmpty else {
            throw GrokSTTError.noCredentialConfigured
        }
        return GrokSTTCredential(
            bearer: key,
            source: .apiKey,
            expiresAt: nil,
            accountLabel: nil
        )
    }

    private func resolveCLISession(allowRefresh: Bool, exclude: String? = nil) async throws -> GrokSTTCredential {
        let entries: [GrokCLIAuthLoadedEntry]
        do {
            entries = try self.dependencies.authStore.loadEntries()
        } catch GrokSTTError.grokStoreParseFailed {
            throw GrokSTTError.grokStoreParseFailed
        } catch GrokSTTError.grokStoreUnreadable {
            throw GrokSTTError.grokStoreUnreadable
        } catch {
            throw GrokSTTError.noCredentialConfigured
        }

        // 401 recovery (allowRefresh == false): only unexpired entries. Ordinary
        // bb scoring would otherwise prefer an expired self-consistent entry (2)
        // over a live mismatched alternate (1) and then throw because refresh is off.
        let candidates = allowRefresh ? entries : entries.filter { !$0.isExpired }
        let picked = self.dependencies.authStore.pick(from: candidates, previousKeys: [:], exclude: exclude)
        guard let picked else {
            throw exclude == nil ? GrokSTTError.noCredentialConfigured : GrokSTTError.unauthorized
        }

        if !picked.isExpired {
            return self.dependencies.authStore.credential(from: picked)
        }

        guard allowRefresh else {
            throw GrokSTTError.unauthorized
        }

        let previous = self.dependencies.authStore.keySnapshot(from: entries)
        try await self.refreshCLISession(authPath: self.dependencies.authStore.resolvePath())

        let refreshed: [GrokCLIAuthLoadedEntry]
        do {
            refreshed = try self.dependencies.authStore.loadEntries()
        } catch {
            throw GrokSTTError.grokSessionExpired
        }
        guard let next = self.dependencies.authStore.pick(
            from: refreshed,
            previousKeys: previous,
            exclude: exclude
        ), !next.isExpired else {
            throw GrokSTTError.grokSessionExpired
        }
        return self.dependencies.authStore.credential(from: next)
    }

    private func refreshCLISession(authPath: String) async throws {
        let task: Task<Void, Error> = self.lock.withLock {
            if let inFlight = self.inFlightRefresh {
                return inFlight
            }
            let spawned = Task<Void, Error>.detached { [dependencies] in
                let executable = try dependencies.binaryLocator.locate()
                try await dependencies.refresh.refreshSession(
                    executable: executable,
                    authPath: authPath,
                    environment: dependencies.processEnvironment()
                )
            }
            let refreshID = UUID()
            self.inFlightRefresh = spawned
            self.inFlightRefreshID = refreshID
            Task.detached { [weak self] in
                _ = try? await spawned.value
                guard let self else { return }
                self.lock.withLock {
                    guard self.inFlightRefreshID == refreshID else { return }
                    self.inFlightRefresh = nil
                    self.inFlightRefreshID = nil
                }
            }
            return spawned
        }

        try await self.awaitRefresh(task)
    }

    private func awaitRefresh(_ task: Task<Void, Error>) async throws {
        let budget = max(self.dependencies.refreshWaitBudget, 0)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = FirstWinsResumeBox()
            Task.detached {
                do {
                    try await task.value
                    box.resume(continuation, result: .success(()))
                } catch {
                    box.resume(continuation, result: .failure(error))
                }
            }
            Task.detached {
                let nanoseconds = UInt64(budget * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                box.resume(continuation, result: .failure(GrokSTTError.refreshInProgress))
            }
        }
    }
}

private final nonisolated class FirstWinsResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Void, Error>, result: Result<Void, Error>) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.resumed else { return }
        self.resumed = true
        continuation.resume(with: result)
    }
}
