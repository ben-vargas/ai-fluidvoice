import Foundation

nonisolated struct GrokCLIAuthEntry: Decodable, Equatable, Sendable {
    let key: String
    let expires_at: String?
    let oidc_issuer: String?
    let oidc_client_id: String?
    let email: String?

    /// Explicitly NO refresh_token. A coding key for it must not exist.
    /// JSONDecoder ignores unknown keys by default — a store that contains
    /// refresh_token still parses; we never decode or persist that field.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case key
        case expires_at
        case oidc_issuer
        case oidc_client_id
        case email
    }

    init(
        key: String,
        expires_at: String? = nil,
        oidc_issuer: String? = nil,
        oidc_client_id: String? = nil,
        email: String? = nil
    ) {
        self.key = key
        self.expires_at = expires_at
        self.oidc_issuer = oidc_issuer
        self.oidc_client_id = oidc_client_id
        self.email = email
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.expires_at = try container.decodeIfPresent(String.self, forKey: .expires_at)
        self.oidc_issuer = try container.decodeIfPresent(String.self, forKey: .oidc_issuer)
        self.oidc_client_id = try container.decodeIfPresent(String.self, forKey: .oidc_client_id)
        self.email = try container.decodeIfPresent(String.self, forKey: .email)
    }
}

nonisolated struct GrokCLIAuthLoadedEntry: Equatable, Sendable {
    let scopeKey: String
    let entry: GrokCLIAuthEntry
    let expiresAt: Date?
    let isExpired: Bool
    let isSelfConsistent: Bool
}

nonisolated enum GrokCLISessionStatus: Equatable, Sendable {
    case missing
    case unreadable
    case parseFailed
    case empty
    case available(email: String?, expired: Bool)
}

nonisolated struct GrokCLIAuthStore: Sendable {
    static let maxFileBytes = 1_048_576
    static let expirySkew: TimeInterval = 300

    var fileSystem: any GrokSTTFileReading
    var environment: @Sendable () -> [String: String]
    var homeDirectory: @Sendable () -> URL
    var now: @Sendable () -> Date

    init(
        fileSystem: any GrokSTTFileReading = GrokSTTFoundationFileSystem(),
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileSystem = fileSystem
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.now = now
    }

    /// Defined `GROK_AUTH_PATH` is literal even if empty; else `$GROK_HOME/auth.json` (empty `GROK_HOME` falls back); else `~/.grok/auth.json`.
    func resolvePath() -> String {
        let environment = self.environment()
        if let grokAuthPath = environment["GROK_AUTH_PATH"] {
            return grokAuthPath
        }
        let grokHome = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let grokHome, !grokHome.isEmpty {
            return Self.join(self.expandHome(grokHome), "auth.json")
        }
        return self.homeDirectory().appendingPathComponent(".grok/auth.json").path
    }

    func hasReadableKey() -> Bool {
        do {
            return try !self.loadEntries().isEmpty
        } catch {
            return false
        }
    }

    func sessionStatus() -> GrokCLISessionStatus {
        let path = self.resolvePath()
        if path.isEmpty {
            return .missing
        }
        let url = URL(fileURLWithPath: path)
        guard self.fileSystem.fileExists(at: url) else {
            return .missing
        }
        do {
            let entries = try self.loadEntries()
            guard let picked = self.pick(from: entries, previousKeys: [:], exclude: nil) else {
                return .empty
            }
            return .available(email: picked.entry.email, expired: picked.isExpired)
        } catch GrokSTTError.grokStoreParseFailed {
            return .parseFailed
        } catch GrokSTTError.grokStoreUnreadable {
            return .unreadable
        } catch GrokSTTError.noCredentialConfigured {
            return .empty
        } catch {
            return .unreadable
        }
    }

    func loadEntries() throws -> [GrokCLIAuthLoadedEntry] {
        let path = self.resolvePath()
        guard !path.isEmpty else {
            throw GrokSTTError.noCredentialConfigured
        }
        let url = URL(fileURLWithPath: path)
        guard self.fileSystem.fileExists(at: url) else {
            throw GrokSTTError.noCredentialConfigured
        }

        let byteCount: Int
        do {
            byteCount = try self.fileSystem.byteCount(at: url)
        } catch {
            throw GrokSTTError.grokStoreUnreadable
        }
        guard byteCount <= Self.maxFileBytes else {
            throw GrokSTTError.grokStoreParseFailed
        }

        let data: Data
        do {
            data = try self.fileSystem.contents(at: url)
        } catch {
            throw GrokSTTError.grokStoreUnreadable
        }
        guard data.count <= Self.maxFileBytes else {
            throw GrokSTTError.grokStoreParseFailed
        }

        return try self.decodeEntries(from: data)
    }

    func decodeEntries(from data: Data) throws -> [GrokCLIAuthLoadedEntry] {
        let object: [String: GrokCLIAuthEntry]
        do {
            object = try JSONDecoder().decode([String: GrokCLIAuthEntry].self, from: data)
        } catch {
            throw GrokSTTError.grokStoreParseFailed
        }

        let orderedKeys = GrokCLIOrderedJSONKeys.keys(in: data)
        let keys = orderedKeys.isEmpty ? Array(object.keys) : orderedKeys
        let now = self.now()
        var loaded: [GrokCLIAuthLoadedEntry] = []
        loaded.reserveCapacity(object.count)

        for scopeKey in keys {
            guard let entry = object[scopeKey] else { continue }
            let trimmedKey = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else { continue }
            let expiresAt = Self.parseExpiry(entry.expires_at)
            let isExpired = Self.isExpired(expiresAt, now: now)
            let issuer = entry.oidc_issuer ?? ""
            let client = entry.oidc_client_id ?? ""
            let expectedScope = "\(issuer)::\(client)"
            let isSelfConsistent = !issuer.isEmpty && !client.isEmpty && scopeKey == expectedScope
            loaded.append(
                GrokCLIAuthLoadedEntry(
                    scopeKey: scopeKey,
                    entry: entry,
                    expiresAt: expiresAt,
                    isExpired: isExpired,
                    isSelfConsistent: isSelfConsistent
                )
            )
        }
        return loaded
    }

    func pick(
        from entries: [GrokCLIAuthLoadedEntry],
        previousKeys: [String: String],
        exclude: String?
    ) -> GrokCLIAuthLoadedEntry? {
        let eligible = entries.filter { entry in
            if let exclude, Self.isExcluded(entry.entry.key, rejected: exclude) {
                return false
            }
            return true
        }
        guard !eligible.isEmpty else { return nil }

        var best: GrokCLIAuthLoadedEntry?
        var bestScore = Int.min
        for entry in eligible {
            let rotated = Self.isRotated(entry, previousKeys: previousKeys)
            let score = (rotated ? 4 : 0) + (entry.isSelfConsistent ? 2 : 0) + (entry.isExpired ? 0 : 1)
            if score > bestScore {
                bestScore = score
                best = entry
            }
        }
        return best
    }

    func keySnapshot(from entries: [GrokCLIAuthLoadedEntry]) -> [String: String] {
        var snapshot: [String: String] = [:]
        for entry in entries {
            snapshot[entry.scopeKey] = entry.entry.key
        }
        return snapshot
    }

    func credential(from entry: GrokCLIAuthLoadedEntry) -> GrokSTTCredential {
        GrokSTTCredential(
            bearer: entry.entry.key,
            source: .grokCLISession,
            expiresAt: entry.expiresAt,
            accountLabel: entry.entry.email
        )
    }

    static func isExpired(_ expiresAt: Date?, now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt.addingTimeInterval(-Self.expirySkew)
    }

    static func parseExpiry(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatters: [ISO8601DateFormatter] = {
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return [withFractional, plain]
        }()
        for formatter in formatters {
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        if let seconds = TimeInterval(raw) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    private static func isRotated(_ entry: GrokCLIAuthLoadedEntry, previousKeys: [String: String]) -> Bool {
        guard !entry.isExpired, let previous = previousKeys[entry.scopeKey] else { return false }
        return previous != entry.entry.key
    }

    private static func isExcluded(_ key: String, rejected: String) -> Bool {
        GrokSTTCredential.matchesRejectedBearer(key, rejected: rejected)
    }

    private func expandHome(_ path: String) -> String {
        if path == "~" {
            return self.homeDirectory().path
        }
        if path.hasPrefix("~/") {
            return self.homeDirectory().appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

    private static func join(_ directory: String, _ name: String) -> String {
        if directory.hasSuffix("/") {
            return directory + name
        }
        return directory + "/" + name
    }
}

nonisolated enum GrokCLIOrderedJSONKeys {
    static func keys(in data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var keys: [String] = []
        var index = text.startIndex
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == "{" else { return [] }
        index = text.index(after: index)

        var depth = 1
        var inString = false
        var escaping = false
        var collectingKey = false
        var keyStart: String.Index?
        var expectingKey = true

        while index < text.endIndex, depth > 0 {
            let character = text[index]
            if inString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                    if collectingKey, let keyStart {
                        keys.append(String(text[keyStart..<index]))
                        collectingKey = false
                        expectingKey = false
                    }
                }
            } else if character == "\"" {
                inString = true
                if depth == 1, expectingKey {
                    collectingKey = true
                    keyStart = text.index(after: index)
                }
            } else if character == "{" || character == "[" {
                depth += 1
            } else if character == "}" || character == "]" {
                depth -= 1
            } else if character == ",", depth == 1 {
                expectingKey = true
            }
            index = text.index(after: index)
        }
        return keys
    }
}
