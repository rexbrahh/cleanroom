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

            do {
                try process.run()
            } catch {
                return CommandResult(
                    executable: executable,
                    arguments: arguments,
                    exitCode: -1,
                    launchError: error.localizedDescription
                )
            }

            let deadline = Date().addingTimeInterval(max(timeout, 0.1))
            var timedOut = false
            while process.isRunning {
                if Date() >= deadline {
                    timedOut = true
                    process.terminate()
                    Darwin.usleep(200_000)
                    if process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                    break
                }
                Darwin.usleep(20_000)
            }
            process.waitUntilExit()
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
                timedOut: timedOut
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
