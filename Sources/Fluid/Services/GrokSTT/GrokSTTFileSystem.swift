import Foundation

nonisolated protocol GrokSTTFileReading: Sendable {
    func fileExists(at url: URL) -> Bool
    func isExecutableFile(at url: URL) -> Bool
    func contents(at url: URL) throws -> Data
    func byteCount(at url: URL) throws -> Int
}

nonisolated struct GrokSTTFoundationFileSystem: GrokSTTFileReading {
    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func isExecutableFile(at url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    func contents(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func byteCount(at url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }
}
