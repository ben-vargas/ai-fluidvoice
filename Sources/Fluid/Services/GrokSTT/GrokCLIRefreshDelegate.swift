import Foundation

nonisolated struct GrokCLIProcessRequest: Equatable, Sendable {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
}

nonisolated protocol GrokCLILaunchedProcess: Sendable {
    var isRunning: Bool { get }
    func waitUntilExit() async
}

nonisolated protocol GrokCLIProcessLaunching: Sendable {
    func launch(_ request: GrokCLIProcessRequest) throws -> any GrokCLILaunchedProcess
}

nonisolated protocol GrokCLIRefreshing: Sendable {
    /// Spawn `grok sessions list -n 1`. Never kill the child. Never spawn a bare `"grok"`.
    func refreshSession(executable: URL, authPath: String, environment: [String: String]) async throws
}

final nonisolated class FoundationGrokCLIProcess: GrokCLILaunchedProcess, @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    var isRunning: Bool {
        self.process.isRunning
    }

    func waitUntilExit() async {
        let box = ContinuationResumeBox()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.process.terminationHandler = { _ in
                box.resume(continuation)
            }
            if !self.process.isRunning {
                box.resume(continuation)
            }
        }
    }
}

private final nonisolated class ContinuationResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Void, Never>) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.resumed else { return }
        self.resumed = true
        continuation.resume()
    }
}

nonisolated struct FoundationGrokCLIProcessLauncher: GrokCLIProcessLaunching {
    func launch(_ request: GrokCLIProcessRequest) throws -> any GrokCLILaunchedProcess {
        guard request.executable.path.hasPrefix("/") else {
            throw GrokSTTError.grokCLINotFound
        }
        guard request.arguments == ["sessions", "list", "-n", "1"] else {
            throw GrokSTTError.grokCLINotFound
        }

        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw GrokSTTError.grokCLINotFound
        }
        return FoundationGrokCLIProcess(process)
    }
}

/// Delegated CLI refresh. Never writes `auth.json`. Never decodes `refresh_token`. Never `terminate()`.
final nonisolated class GrokCLIRefreshDelegate: GrokCLIRefreshing, @unchecked Sendable {
    private let launcher: any GrokCLIProcessLaunching
    private let lock = NSLock()
    private var retainedProcess: (any GrokCLILaunchedProcess)?

    init(launcher: any GrokCLIProcessLaunching = FoundationGrokCLIProcessLauncher()) {
        self.launcher = launcher
    }

    func refreshSession(executable: URL, authPath: String, environment: [String: String]) async throws {
        guard executable.path.hasPrefix("/") else {
            throw GrokSTTError.grokCLINotFound
        }

        var childEnvironment = environment
        childEnvironment["GROK_AUTH_PATH"] = authPath
        let request = GrokCLIProcessRequest(
            executable: executable,
            arguments: ["sessions", "list", "-n", "1"],
            environment: childEnvironment
        )

        let process: any GrokCLILaunchedProcess
        do {
            process = try self.launcher.launch(request)
        } catch {
            throw GrokSTTError.grokCLINotFound
        }

        self.lock.lock()
        self.retainedProcess = process
        self.lock.unlock()

        await process.waitUntilExit()
    }
}
