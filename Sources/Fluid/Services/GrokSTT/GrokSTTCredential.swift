import CryptoKit
import Foundation

/// How the user chose to authenticate Grok Speech. Explicit — never a silent fallback.
nonisolated enum GrokSTTAuthMode: String, Sendable, Equatable {
    case apiKey
    case grokCLISession
}

nonisolated enum GrokSTTCredentialSource: String, Sendable, Equatable {
    case apiKey
    case grokCLISession
    // Future B: case grokDeviceFlow
}

nonisolated struct GrokSTTCredential: Sendable, Equatable {
    let bearer: String
    let source: GrokSTTCredentialSource
    let expiresAt: Date?
    let accountLabel: String?

    /// SHA-256 hex of the bearer. Safe to compare; never log the bearer itself.
    var bearerFingerprint: String {
        Self.fingerprint(self.bearer)
    }

    static func fingerprint(_ bearer: String) -> String {
        let digest = SHA256.hash(data: Data(bearer.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// True when `rejected` is the raw bearer, the full fingerprint, or a unique prefix of it.
    static func matchesRejectedBearer(_ bearer: String, rejected: String) -> Bool {
        if bearer == rejected {
            return true
        }
        let fingerprint = Self.fingerprint(bearer)
        if fingerprint == rejected {
            return true
        }
        if rejected.count >= 8, fingerprint.hasPrefix(rejected) {
            return true
        }
        return false
    }
}

extension GrokSTTCredential: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { self.debugDescription }

    var debugDescription: String {
        "GrokSTTCredential(source: \(self.source.rawValue), expiresAt: \(String(describing: self.expiresAt)), accountLabel: \(self.accountLabel ?? "nil"))"
    }
}
