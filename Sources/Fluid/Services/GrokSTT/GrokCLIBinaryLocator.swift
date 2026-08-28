import Foundation

nonisolated protocol GrokCLIBinaryLocating: Sendable {
    func locate() throws -> URL
}

/// Find `grok` without GUI PATH. Never returns a bare `"grok"` executable name.
nonisolated struct GrokCLIBinaryLocator: GrokCLIBinaryLocating, Sendable {
    var fileSystem: any GrokSTTFileReading
    var homeDirectory: @Sendable () -> URL
    var userOverride: @Sendable () -> String?

    init(
        fileSystem: any GrokSTTFileReading = GrokSTTFoundationFileSystem(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        userOverride: @escaping @Sendable () -> String? = {
            UserDefaults.standard.string(forKey: SettingsStore.grokCLIBinaryPathDefaultsKey)
        }
    ) {
        self.fileSystem = fileSystem
        self.homeDirectory = homeDirectory
        self.userOverride = userOverride
    }

    func locate() throws -> URL {
        if let override = self.normalizedOverride(), self.isUsable(override) {
            return override
        }

        let candidates = [
            self.homeDirectory().appendingPathComponent(".grok/bin/grok"),
            URL(fileURLWithPath: "/opt/homebrew/bin/grok"),
            URL(fileURLWithPath: "/usr/local/bin/grok"),
        ]
        if let match = candidates.first(where: { self.isUsable($0) }) {
            return match
        }
        throw GrokSTTError.grokCLINotFound
    }

    private func normalizedOverride() -> URL? {
        guard let raw = self.userOverride()?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw == "grok" || (!raw.hasPrefix("/") && !raw.hasPrefix("~")) {
            return nil
        }
        let expanded: String
        if raw == "~" {
            expanded = self.homeDirectory().path
        } else if raw.hasPrefix("~/") {
            expanded = self.homeDirectory().appendingPathComponent(String(raw.dropFirst(2))).path
        } else {
            expanded = raw
        }
        guard (expanded as NSString).isAbsolutePath else {
            return nil
        }
        return URL(fileURLWithPath: expanded)
    }

    private func isUsable(_ url: URL) -> Bool {
        guard (url.path as NSString).isAbsolutePath else { return false }
        return self.fileSystem.isExecutableFile(at: url)
    }
}
