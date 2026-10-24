import Foundation

/// Raw outcome of one git invocation. Parsing happens in `GitQuery`, never here.
public struct GitResult: Sendable, Equatable {
    public let arguments: [String]
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(arguments: [String], exitCode: Int32, standardOutput: Data, standardError: Data) {
        self.arguments = arguments
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    /// stderr as text, trimmed — for error messages only.
    public var errorText: String {
        String(decoding: standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum GitError: Error, Equatable, CustomStringConvertible {
    /// The git executable could not be started at all (missing binary, bad working directory).
    case launchFailed(executable: String, reason: String)
    /// git ran but exited with a code the query does not accept.
    case commandFailed(arguments: [String], exitCode: Int32, message: String)
    /// git succeeded but printed something the parser does not understand.
    case unexpectedOutput(query: String, detail: String)

    public var description: String {
        switch self {
        case let .launchFailed(executable, reason):
            return "Could not run \(executable): \(reason)"
        case let .commandFailed(arguments, exitCode, message):
            return "git \(arguments.joined(separator: " ")) failed (exit \(exitCode)): \(message)"
        case let .unexpectedOutput(query, detail):
            return "Unexpected output from \(query): \(detail)"
        }
    }
}

/// The only boundary through which Merge Desk runs git. Everything above it is testable with real fixture
/// repositories or a fake client.
public protocol GitClient: Sendable {
    /// Runs git with an argv list (never a shell string) in `directory`, adding `environment` on top of the
    /// client's own environment. Returns whatever git produced, whatever the exit code.
    func run(_ arguments: [String], in directory: URL, environment: [String: String]) async throws -> GitResult
}

extension GitClient {
    public func run(_ arguments: [String], in directory: URL) async throws -> GitResult {
        try await run(arguments, in: directory, environment: [:])
    }

    /// Runs a typed query and parses its output; exit codes outside the query's accepted set become `GitError`.
    public func execute<Output>(_ query: GitQuery<Output>, in directory: URL) async throws -> Output {
        let result = try await run(query.arguments, in: directory)
        guard query.acceptedExitCodes.contains(result.exitCode) else {
            throw GitError.commandFailed(arguments: query.arguments, exitCode: result.exitCode, message: result.errorText)
        }
        return try query.parse(result)
    }
}

/// Runs the system git through `Process`.
public struct ProcessGitClient: GitClient {
    /// Variables that keep git non-interactive and its output stable for parsing:
    /// no credential prompts, English messages, and no optional index locks (so a background refresh never
    /// blocks the developer's own git commands).
    public static let baseEnvironment: [String: String] = [
        "GIT_TERMINAL_PROMPT": "0",
        "LC_ALL": "C",
        "GIT_OPTIONAL_LOCKS": "0",
    ]

    public let executableURL: URL
    private let environment: [String: String]

    /// - Parameters:
    ///   - executableURL: git binary to run.
    ///   - environmentOverrides: extra variables for every call (tests use this to isolate from user config).
    public init(
        executableURL: URL = URL(fileURLWithPath: MergeDeskConstants.defaultGitExecutablePath),
        environmentOverrides: [String: String] = [:]
    ) {
        self.executableURL = executableURL
        self.environment = ProcessInfo.processInfo.environment
            .merging(Self.baseEnvironment) { _, new in new }
            .merging(environmentOverrides) { _, new in new }
    }

    public func run(_ arguments: [String], in directory: URL, environment extra: [String: String]) async throws -> GitResult {
        try Task.checkCancellation()
        let invocation = GitInvocation(
            executableURL: executableURL,
            arguments: arguments,
            directory: directory,
            environment: environment.merging(extra) { _, new in new }
        )
        let result = try await withTaskCancellationHandler {
            try await invocation.run()
        } onCancel: {
            invocation.cancel()
        }
        // A cancelled run was terminated mid-way; its partial output must not be parsed.
        try Task.checkCancellation()
        return result
    }
}

/// One running git process. Owns the `Process` so cancellation can reach it from another thread; the lock
/// guards the launch/terminate race (terminating a process that never launched raises an exception).
private final class GitInvocation: @unchecked Sendable {
    private let process = Process()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let lock = NSLock()
    private var isCancelled = false
    private let arguments: [String]

    init(executableURL: URL, arguments: [String], directory: URL, environment: [String: String]) {
        self.arguments = arguments
        process.executableURL = executableURL
        process.arguments = arguments
        // Absolute: a relative URL here makes the launch fail on some Foundation versions.
        process.currentDirectoryURL = directory.absoluteURL
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        // git never reads stdin in Merge Desk; an empty stdin stops any accidental prompt from hanging.
        process.standardInput = FileHandle.nullDevice
    }

    func run() async throws -> GitResult {
        try await withCheckedThrowingContinuation { continuation in
            // Blocking reads happen off the cooperative pool so many parallel git calls can't starve it.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.launch()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // Drain stderr concurrently with stdout: a full pipe buffer on either would deadlock git.
                let errorData = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errorData.value = self.errorPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outputData = self.outputPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                self.process.waitUntilExit()
                continuation.resume(returning: GitResult(
                    arguments: self.arguments,
                    exitCode: self.process.terminationStatus,
                    standardOutput: outputData,
                    standardError: errorData.value
                ))
            }
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        if process.isRunning { process.terminate() }
    }

    private func launch() throws {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled { throw CancellationError() }
        do {
            try process.run()
        } catch {
            throw GitError.launchFailed(executable: process.executableURL?.path ?? "git", reason: error.localizedDescription)
        }
    }
}

/// Mutable holder written by exactly one reader thread and read after `DispatchGroup.wait()`.
private final class DataBox: @unchecked Sendable {
    var value = Data()
}
