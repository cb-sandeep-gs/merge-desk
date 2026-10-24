import Foundation

/// `git version` as comparable numbers ("git version 2.50.1 (Apple Git-155)" → 2.50.1).
public struct GitVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: GitVersion, rhs: GitVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// A local branch or a remote-tracking branch.
public struct GitRef: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        case local
        case remote(name: String)
    }

    /// Full ref, e.g. `refs/remotes/origin/feature/x`.
    public let fullName: String
    public let kind: Kind
    /// Branch name without the remote, e.g. `feature/x` for both `refs/heads/feature/x` and `origin/feature/x`.
    public let branchName: String
    public let objectID: String
    public let committerDate: Date
    public let authorName: String
    /// Without the surrounding angle brackets.
    public let authorEmail: String
    /// Upstream full ref for local branches that track one.
    public let upstream: String?

    /// What git prints in short form: `feature/x` (local) or `origin/feature/x` (remote).
    public var shortName: String {
        switch kind {
        case .local: return branchName
        case let .remote(remote): return "\(remote)/\(branchName)"
        }
    }
}

/// Commit counts between a branch and a base it is compared with.
public struct AheadBehind: Sendable, Equatable {
    /// Commits on the branch that the base does not have.
    public let ahead: Int
    /// Commits on the base that the branch does not have.
    public let behind: Int

    public init(ahead: Int, behind: Int) {
        self.ahead = ahead
        self.behind = behind
    }
}

/// Outcome of `git merge-tree --write-tree`: the merge computed in the object store, no worktree touched.
public struct MergeTreeResult: Sendable, Equatable {
    /// One informational message from git, e.g. type `CONFLICT (contents)` for paths `[f.swift]`.
    public struct Message: Sendable, Equatable {
        public let paths: [String]
        public let type: String
        public let text: String
    }

    /// Tree the merge produced (with conflict markers in conflicted files).
    public let treeID: String
    public let conflictedPaths: [String]
    public let messages: [Message]

    public var isClean: Bool { conflictedPaths.isEmpty }
}

/// `git status --porcelain=v2 --branch -z`, reduced to what merge preflight needs.
public struct WorkingTreeStatus: Sendable, Equatable {
    public enum EntryKind: Sendable, Equatable {
        case changed
        case renamedOrCopied
        case unmerged
        case untracked
        case ignored
    }

    public struct Entry: Sendable, Equatable {
        public let kind: EntryKind
        /// Two-letter index/worktree state (`.M`, `UU`, …); `??` / `!!` for untracked / ignored.
        public let state: String
        public let path: String
        /// Source path of a rename or copy.
        public let originalPath: String?
    }

    /// `nil` when HEAD is detached.
    public let branch: String?
    /// `nil` on an unborn branch (no commits yet).
    public let headObjectID: String?
    public let upstream: String?
    public let ahead: Int?
    public let behind: Int?
    public let entries: [Entry]

    /// True when nothing tracked or untracked differs from HEAD (ignored files don't count).
    public var isClean: Bool { entries.allSatisfy { $0.kind == .ignored } }
    public var hasConflicts: Bool { entries.contains { $0.kind == .unmerged } }
}
