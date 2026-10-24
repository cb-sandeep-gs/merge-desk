import Foundation

/// A git command paired with the parser for its output, so the format string and the parser can never drift
/// apart. Every query uses NUL-separated or porcelain output only — never human-readable text.
public struct GitQuery<Output>: Sendable {
    public let name: String
    public let arguments: [String]
    public let acceptedExitCodes: Set<Int32>
    public let parse: @Sendable (GitResult) throws -> Output

    public init(
        name: String,
        arguments: [String],
        acceptedExitCodes: Set<Int32> = [GitExitCode.success],
        parse: @escaping @Sendable (GitResult) throws -> Output
    ) {
        self.name = name
        self.arguments = arguments
        self.acceptedExitCodes = acceptedExitCodes
        self.parse = parse
    }
}

public enum GitExitCode {
    public static let success: Int32 = 0
    /// `merge-tree` conflicts, `merge-base --is-ancestor` "no" — and, for some commands, plain errors.
    public static let one: Int32 = 1
}

public enum RefNamespace {
    public static let localBranches = "refs/heads"
    public static let remoteBranches = "refs/remotes"
}

extension GitQuery where Output == GitVersion {
    public static var version: GitQuery<GitVersion> {
        GitQuery(name: "version", arguments: ["version"]) { result in
            try GitOutputParser.parseVersion(String(decoding: result.standardOutput, as: UTF8.self))
        }
    }
}

extension GitQuery where Output == URL {
    /// Top-level folder of the repository containing the working directory.
    public static var repositoryRoot: GitQuery<URL> {
        GitQuery(name: "rev-parse --show-toplevel", arguments: ["rev-parse", "--show-toplevel"]) { result in
            let path = GitOutputParser.trimmedLine(result.standardOutput)
            guard !path.isEmpty else { throw GitError.unexpectedOutput(query: "rev-parse --show-toplevel", detail: "empty path") }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }
}

extension GitQuery where Output == String {
    /// Resolves any revision to a full commit id.
    public static func commitID(of revision: String) -> GitQuery<String> {
        GitQuery(name: "rev-parse", arguments: ["rev-parse", "--verify", "--end-of-options", "\(revision)^{commit}"]) { result in
            GitOutputParser.trimmedLine(result.standardOutput)
        }
    }

    public static func mergeBase(_ first: String, _ second: String) -> GitQuery<String> {
        GitQuery(name: "merge-base", arguments: ["merge-base", "--end-of-options", first, second]) { result in
            GitOutputParser.trimmedLine(result.standardOutput)
        }
    }
}

extension GitQuery where Output == Bool {
    /// Whether `ancestor` is reachable from `descendant` — i.e. "already merged".
    public static func isAncestor(_ ancestor: String, of descendant: String) -> GitQuery<Bool> {
        GitQuery(
            name: "merge-base --is-ancestor",
            arguments: ["merge-base", "--is-ancestor", "--end-of-options", ancestor, descendant],
            acceptedExitCodes: [GitExitCode.success, GitExitCode.one]
        ) { result in
            result.exitCode == GitExitCode.success
        }
    }
}

extension GitQuery where Output == [GitRef] {
    /// Local and remote-tracking branches, symbolic refs (like `origin/HEAD`) excluded.
    public static func branches(
        namespaces: [String] = [RefNamespace.localBranches, RefNamespace.remoteBranches]
    ) -> GitQuery<[GitRef]> {
        GitQuery(
            name: "for-each-ref",
            arguments: ["for-each-ref", "--format=\(GitOutputParser.refFormat)"] + namespaces
        ) { result in
            try GitOutputParser.parseRefs(result.standardOutput)
        }
    }
}

extension GitQuery where Output == AheadBehind {
    /// How far `branch` is ahead of / behind `base`.
    public static func aheadBehind(branch: String, base: String) -> GitQuery<AheadBehind> {
        GitQuery(
            name: "rev-list --left-right --count",
            arguments: ["rev-list", "--left-right", "--count", "\(base)...\(branch)", "--"]
        ) { result in
            try GitOutputParser.parseLeftRightCount(result.standardOutput)
        }
    }
}

extension GitQuery where Output == MergeTreeResult {
    /// Predicts merging `source` into `target` without touching any worktree or ref.
    public static func mergeTree(target: String, source: String) -> GitQuery<MergeTreeResult> {
        GitQuery(
            name: "merge-tree",
            arguments: ["merge-tree", "--write-tree", "--name-only", "-z", "--end-of-options", target, source],
            // 1 means "conflicts" — or an error such as an unknown ref; the parser tells them apart.
            acceptedExitCodes: [GitExitCode.success, GitExitCode.one]
        ) { result in
            try GitOutputParser.parseMergeTree(result)
        }
    }
}

extension GitQuery where Output == WorkingTreeStatus {
    public static var status: GitQuery<WorkingTreeStatus> {
        GitQuery(
            name: "status",
            arguments: ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]
        ) { result in
            try GitOutputParser.parseStatus(result.standardOutput)
        }
    }
}
