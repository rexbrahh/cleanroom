import Darwin
import Foundation

public struct CommandResult: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let timedOut: Bool
    public let launchError: String?

    public var succeeded: Bool {
        launchError == nil && !timedOut && exitCode == 0
    }

    public init(
        executable: String,
        arguments: [String],
        exitCode: Int32,
        standardOutput: String = "",
        standardError: String = "",
        timedOut: Bool = false,
        launchError: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
        self.launchError = launchError
    }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) async -> CommandResult
    func start(_ executable: String, arguments: [String]) async -> CommandResult
}

public struct LocalCommandRunner: CommandRunning, Sendable {
    public init() {}

    public func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = 8
    ) async -> CommandResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            let temporaryDirectory = FileManager.default.temporaryDirectory
            let standardOutputURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let standardErrorURL = temporaryDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
            FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil)
            guard let standardOutput = FileHandle(forWritingAtPath: standardOutputURL.path),
                let standardError = FileHandle(forWritingAtPath: standardErrorURL.path)
            else {
                return CommandResult(
                    executable: executable,
                    arguments: arguments,
                    exitCode: -1,
                    launchError: "Could not allocate command output files."
                )
            }
            defer {
                try? standardOutput.close()
                try? standardError.close()
                try? FileManager.default.removeItem(at: standardOutputURL)
                try? FileManager.default.removeItem(at: standardErrorURL)
            }
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = standardOutput
            process.standardError = standardError

            // Completion is delivered through terminationHandler instead of a
            // 20ms isRunning poll, so fast commands return in milliseconds
            // rather than paying a polling-floor latency on every invocation.
            let completion = await withCheckedContinuation { continuation in
                let gate = ProcessCompletionGate(continuation)
                process.terminationHandler = { _ in gate.finish(timedOut: false) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    gate.finish(timedOut: false, launchError: error.localizedDescription)
                    return
                }
                gate.armTimeout(after: max(timeout, 0.1), process: process)
            }
            if let launchError = completion.launchError {
                return CommandResult(
                    executable: executable,
                    arguments: arguments,
                    exitCode: -1,
                    launchError: launchError
                )
            }

            try? standardOutput.synchronize()
            try? standardError.synchronize()
            let outputData = (try? Data(contentsOf: standardOutputURL)) ?? Data()
            let errorData = (try? Data(contentsOf: standardErrorURL)) ?? Data()
            return CommandResult(
                executable: executable,
                arguments: arguments,
                exitCode: process.terminationStatus,
                standardOutput: String(decoding: outputData, as: UTF8.self),
                standardError: String(decoding: errorData, as: UTF8.self),
                timedOut: completion.timedOut
            )
        }.value
    }

    public func start(_ executable: String, arguments: [String]) async -> CommandResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
                return CommandResult(
                    executable: executable,
                    arguments: arguments,
                    exitCode: 0,
                    standardOutput: String(process.processIdentifier)
                )
            } catch {
                return CommandResult(
                    executable: executable,
                    arguments: arguments,
                    exitCode: -1,
                    launchError: error.localizedDescription
                )
            }
        }.value
    }
}

private struct ProcessCompletion {
    let timedOut: Bool
    let launchError: String?
}

/// Resumes the command continuation exactly once, whether the process exits
/// on its own, fails to launch, or is killed by the timeout watchdog.
private final class ProcessCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessCompletion, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var process: Process?
    private var timeoutTriggered = false

    init(_ continuation: CheckedContinuation<ProcessCompletion, Never>) {
        self.continuation = continuation
    }

    func finish(timedOut: Bool, launchError: String? = nil) {
        lock.lock()
        let taken = continuation
        continuation = nil
        let resolvedTimedOut = timedOut || timeoutTriggered
        timeoutTask?.cancel()
        timeoutTask = nil
        process = nil
        lock.unlock()
        taken?.resume(returning: ProcessCompletion(timedOut: resolvedTimedOut, launchError: launchError))
    }

    func armTimeout(after seconds: TimeInterval, process: Process) {
        let task = Task { [self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            guard let process = beginTimeout() else { return }
            if process.isRunning {
                process.terminate()
                Darwin.usleep(200_000)
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            process.waitUntilExit()
            finish(timedOut: true)
        }
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            task.cancel()
            return
        }
        self.process = process
        timeoutTask = task
        lock.unlock()
    }

    private func beginTimeout() -> Process? {
        lock.lock()
        defer { lock.unlock() }
        guard continuation != nil else { return nil }
        timeoutTriggered = true
        return process
    }
}
