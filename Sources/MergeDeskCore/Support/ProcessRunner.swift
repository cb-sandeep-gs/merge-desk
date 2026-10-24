import Foundation

/// Runs any program (git, launchctl, osascript…) with an argv list and an explicit environment, reading stdout and
/// stderr fully. Cancelling the calling task terminates the process.
public enum ProcessRunner {
    public static func run(
        executableURL: URL, arguments: [String], directory: URL, environment: [String: String]
    ) async throws -> GitResult {
        try Task.checkCancellation()
        let invocation = ProcessInvocation(
            executableURL: executableURL, arguments: arguments, directory: directory, environment: environment
        )
        let result = try await withTaskCancellationHandler {
            try await invocation.run()
        } onCancel: {
            invocation.cancel()
        }
        // A cancelled run was terminated mid-way; its partial output must not be used.
        try Task.checkCancellation()
        return result
    }
}

/// One running process. Owns the `Process` so cancellation can reach it from another thread; the lock
/// guards the launch/terminate race (terminating a process that never launched raises an exception).
private final class ProcessInvocation: @unchecked Sendable {
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
        // Nothing Merge Desk runs reads stdin; an empty stdin stops any accidental prompt from hanging.
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
            throw GitError.launchFailed(executable: process.executableURL?.path ?? "", reason: error.localizedDescription)
        }
    }
}

/// Mutable holder written by exactly one reader thread and read after `DispatchGroup.wait()`.
private final class DataBox: @unchecked Sendable {
    var value = Data()
}
