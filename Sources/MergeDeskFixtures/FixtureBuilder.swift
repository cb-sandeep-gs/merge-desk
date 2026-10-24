import Foundation
import MergeDeskCore

/// A built fixture repository on disk.
public struct FixtureRepository: Sendable {
    public let url: URL
    public let definition: FixtureDefinition
}

public enum FixtureError: Error, Equatable, CustomStringConvertible {
    /// Fixtures are only created in new folders, never over existing files.
    case destinationExists(String)

    public var description: String {
        switch self {
        case let .destinationExists(path): return "\(path) already exists; fixtures are only created in new folders"
        }
    }
}

/// Builds fixture repositories with real git, isolated from the user's git config, hooks and signing so the
/// same steps produce the same history on every machine and in CI.
public struct FixtureBuilder: Sendable {
    /// Deterministic identity and no global/system config (no hooks, signing, rerere or custom merge drivers).
    public static let isolatedEnvironment: [String: String] = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Fixture Author",
        "GIT_AUTHOR_EMAIL": "fixture@example.com",
        "GIT_COMMITTER_NAME": "Fixture Author",
        "GIT_COMMITTER_EMAIL": "fixture@example.com",
    ]

    /// 2026-01-01T00:00:00Z; each commit is one minute after the previous, so histories are reproducible.
    private static let firstCommitEpoch = 1_767_225_600
    private static let secondsBetweenCommits = 60

    private let git: GitClient
    /// `FileManager.default` is thread-safe for these calls; not stored, as `FileManager` isn't `Sendable`.
    private var fileManager: FileManager { .default }

    public init(git: GitClient = ProcessGitClient(environmentOverrides: FixtureBuilder.isolatedEnvironment)) {
        self.git = git
    }

    /// Creates `<parent>/<pattern>` and plays the pattern's steps into it.
    public func build(_ pattern: FixturePattern, in parent: URL) async throws -> FixtureRepository {
        let definition = pattern.definition
        let url = parent.appendingPathComponent(pattern.rawValue, isDirectory: true)
        guard !fileManager.fileExists(atPath: url.path) else { throw FixtureError.destinationExists(url.path) }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)

        try await runGit(["init", "--quiet", "--initial-branch=\(FixtureBranch.base)"], in: url)
        var commitIndex = 0
        for step in definition.steps {
            switch step {
            case let .write(path, contents):
                let file = url.appendingPathComponent(path)
                try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: file)
            case let .delete(path):
                try fileManager.removeItem(at: url.appendingPathComponent(path))
            case let .commit(message):
                try await runGit(["add", "--all"], in: url)
                try await runGit(["commit", "--quiet", "--message", message], in: url, commitIndex: &commitIndex)
            case let .createBranch(name):
                try await runGit(["switch", "--quiet", "--create", name], in: url)
            case let .switchTo(name):
                try await runGit(["switch", "--quiet", name], in: url)
            case let .cherryPickTip(branch):
                try await runGit(["cherry-pick", branch], in: url, commitIndex: &commitIndex)
            case .revertHead:
                try await runGit(["revert", "--no-edit", "HEAD"], in: url, commitIndex: &commitIndex)
            }
        }
        return FixtureRepository(url: url, definition: definition)
    }

    /// Builds every pattern under `parent`.
    public func buildAll(in parent: URL) async throws -> [FixtureRepository] {
        var repositories: [FixtureRepository] = []
        for pattern in FixturePattern.allCases {
            repositories.append(try await build(pattern, in: parent))
        }
        return repositories
    }

    // MARK: - git helpers

    private func runGit(_ arguments: [String], in directory: URL) async throws {
        try check(try await git.run(arguments, in: directory))
    }

    /// Runs a commit-creating command with the next deterministic author/committer date.
    private func runGit(_ arguments: [String], in directory: URL, commitIndex: inout Int) async throws {
        let date = "\(Self.firstCommitEpoch + commitIndex * Self.secondsBetweenCommits) +0000"
        commitIndex += 1
        let result = try await git.run(arguments, in: directory, environment: [
            "GIT_AUTHOR_DATE": date,
            "GIT_COMMITTER_DATE": date,
        ])
        try check(result)
    }

    private func check(_ result: GitResult) throws {
        guard result.exitCode == GitExitCode.success else {
            throw GitError.commandFailed(arguments: result.arguments, exitCode: result.exitCode, message: result.errorText)
        }
    }
}
