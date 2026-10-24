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

/// Deterministic time and identity for fixture commits.
public struct FixtureClock: Sendable {
    public var commitIndex = 0
    public var dayOffset = 0
    /// Overrides the default fixture author for following commits.
    public var author: (name: String, email: String)?

    public init() {}
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
    private static let secondsPerDay = 86_400

    /// 2026-01-01T00:00:00Z, the fixture timeline's day 0.
    public static let firstCommitDate = Date(timeIntervalSince1970: TimeInterval(firstCommitEpoch))

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
        var clock = FixtureClock()
        try await play(definition.steps, in: url, clock: &clock)
        return FixtureRepository(url: url, definition: definition)
    }

    /// Plays steps into an existing repository. `clock` carries commit dates and author across calls, so a
    /// fixture spread over several repositories (origin + clone) keeps one consistent timeline.
    public func play(_ steps: [FixtureStep], in url: URL, clock: inout FixtureClock) async throws {
        for step in steps {
            switch step {
            case .write, .delete:
                try applyFileStep(step, in: url)
            case let .commit(message):
                try await runGit(["add", "--all"], in: url)
                try await runGit(["commit", "--quiet", "--message", message], in: url, clock: &clock)
            case let .createBranch(name):
                try await runGit(["switch", "--quiet", "--create", name], in: url)
            case let .switchTo(name):
                try await runGit(["switch", "--quiet", name], in: url)
            case let .cherryPickTip(branch):
                try await runGit(["cherry-pick", branch], in: url, clock: &clock)
            case .revertHead:
                try await runGit(["revert", "--no-edit", "HEAD"], in: url, clock: &clock)
            case let .advanceDays(days):
                clock.dayOffset += days
            case let .author(name, email):
                clock.author = (name, email)
            case let .git(arguments):
                try await runGit(arguments, in: url, clock: &clock)
            }
        }
    }

    /// Working-tree edits (no git involved).
    private func applyFileStep(_ step: FixtureStep, in url: URL) throws {
        switch step {
        case let .write(path, contents):
            let file = url.appendingPathComponent(path)
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        case let .delete(path):
            try fileManager.removeItem(at: url.appendingPathComponent(path))
        default:
            preconditionFailure("not a file step: \(step)")
        }
    }

    /// Clones `source` into `destination` (a new folder) with the isolated environment.
    public func clone(_ source: URL, to destination: URL) async throws {
        guard !fileManager.fileExists(atPath: destination.path) else { throw FixtureError.destinationExists(destination.path) }
        try await runGit(["clone", "--quiet", "--", source.path, destination.path], in: source.deletingLastPathComponent())
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

    /// Runs a possibly commit-creating command with the next deterministic date and the current author.
    private func runGit(_ arguments: [String], in directory: URL, clock: inout FixtureClock) async throws {
        let seconds = Self.firstCommitEpoch + clock.dayOffset * Self.secondsPerDay + clock.commitIndex * Self.secondsBetweenCommits
        let date = "\(seconds) +0000"
        clock.commitIndex += 1
        var environment = ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date]
        if let author = clock.author {
            environment["GIT_AUTHOR_NAME"] = author.name
            environment["GIT_AUTHOR_EMAIL"] = author.email
        }
        try check(try await git.run(arguments, in: directory, environment: environment))
    }

    private func check(_ result: GitResult) throws {
        guard result.exitCode == GitExitCode.success else {
            throw GitError.commandFailed(arguments: result.arguments, exitCode: result.exitCode, message: result.errorText)
        }
    }
}
