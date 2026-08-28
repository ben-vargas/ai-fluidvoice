import Foundation
import Security

nonisolated protocol GrokSTTAPIKeyStoring: Sendable {
    func loadAPIKey() throws -> String?
    func storeAPIKey(_ key: String) throws
    func deleteAPIKey() throws
}

extension GrokSTTAPIKeyStoring {
    var hasAPIKey: Bool {
        guard let key = try? self.loadAPIKey() else { return false }
        return !key.isEmpty
    }
}

/// Dedicated STT Keychain item. Do not reuse `com.fluidvoice.provider-api-keys` or provider id `"xai"`.
final nonisolated class GrokSTTKeychain: GrokSTTAPIKeyStoring, @unchecked Sendable {
    static let shared = GrokSTTKeychain()

    static let service = "com.fluidvoice.stt-credentials"
    static let account = "xai-stt-api-key"

    private let service: String
    private let account: String

    init(
        service: String = GrokSTTKeychain.service,
        account: String = GrokSTTKeychain.account
    ) {
        self.service = service
        self.account = account
    }

    func loadAPIKey() throws -> String? {
        var query = self.query()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw GrokSTTError.noCredentialConfigured
            }
            if data.isEmpty {
                return nil
            }
            guard let key = String(data: data, encoding: .utf8) else {
                throw GrokSTTError.noCredentialConfigured
            }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case errSecItemNotFound:
            return nil
        default:
            throw GrokSTTError.noCredentialConfigured
        }
    }

    func storeAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try self.deleteAPIKey()
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw GrokSTTError.noCredentialConfigured
        }

        var attributes = self.query()
        attributes[kSecValueData as String] = data
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(
                self.query() as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw GrokSTTError.noCredentialConfigured
            }
        default:
            throw GrokSTTError.noCredentialConfigured
        }
    }

    func deleteAPIKey() throws {
        let status = SecItemDelete(self.query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GrokSTTError.noCredentialConfigured
        }
    }

    private func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
        ]
    }
}

final nonisolated class InMemoryGrokSTTAPIKeyStore: GrokSTTAPIKeyStoring, @unchecked Sendable {
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
