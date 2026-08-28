import Foundation
@testable import FluidVoice_Debug

struct StubGrokSTTResolver: GrokSTTCredentialResolving, Sendable {
    var isSourceConfigured: Bool
    var credential: GrokSTTCredential

    init(isSourceConfigured: Bool = true) {
        self.isSourceConfigured = isSourceConfigured
        self.credential = GrokSTTCredential(
            bearer: "xai-stt-test-key",
            source: .apiKey,
            expiresAt: nil,
            accountLabel: "test"
        )
    }

    func resolveCredential() async throws -> GrokSTTCredential {
        guard self.isSourceConfigured else { throw GrokSTTError.noCredentialConfigured }
        return self.credential
    }

    func resolveCredentialAfterUnauthorized(rejectedBearerFingerprint: String) async throws -> GrokSTTCredential {
        _ = rejectedBearerFingerprint
        throw GrokSTTError.unauthorized
    }
}

final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() {
        self.lock.withLock { self.value += 1 }
    }
    var count: Int {
        self.lock.withLock { self.value }
    }
}

final class TestLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    func park() async {
        await withCheckedContinuation { continuation in
            self.lock.withLock { self.continuation = continuation }
        }
    }

    func resume() {
        let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let value = self.continuation
            self.continuation = nil
            return value
        }
        continuation?.resume()
    }
}

func makeGrokSTTProvider(
    configured: Bool = true,
    session: GrokSTTFakeSession? = nil
) -> GrokSTTProvider {
    let provider = GrokSTTProvider(resolver: StubGrokSTTResolver(isSourceConfigured: configured))
    if let session {
        provider.setSessionFactory { _ in session }
    }
    return provider
}
