import Foundation

/// Single source of truth for names, paths and limits shared by the app, the CLI and the tests.
public enum MergeDeskConstants {
    /// Release version of Merge Desk (app and CLI ship together).
    public static let toolVersion = "0.1.0"

    /// Per-repository configuration file, committed at the repository root.
    public static let configFileName = ".mergedesk.json"

    /// Highest `schemaVersion` of `.mergedesk.json` this build understands.
    public static let supportedConfigSchemaVersion = 1

    /// Ref namespace for the safety copies taken before every merge (`<namespace>/<UTC-timestamp>/<branch>`).
    public static let backupRefNamespace = "refs/mergedesk/backup"

    /// Folder under `~/Library/Application Support` holding sessions, audit logs and digests.
    public static let applicationSupportFolderName = "MergeDesk"

    /// Audit log file name inside each repository's support folder.
    public static let auditLogFileName = "audit.jsonl"

    /// Default git executable; overridable for tests or custom installs.
    public static let defaultGitExecutablePath = "/usr/bin/git"

    /// `git merge-tree --write-tree` (conflict prediction without a worktree) arrived in git 2.38.
    public static let minimumGitVersion = GitVersion(major: 2, minor: 38, patch: 0)

    /// Short hash length used to make repository folder names unique.
    public static let repositoryIdentifierHashLength = 12
}
