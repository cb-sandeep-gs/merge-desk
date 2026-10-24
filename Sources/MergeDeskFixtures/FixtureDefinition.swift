import Foundation

/// One scripted action against a fixture repository.
public enum FixtureStep: Sendable, Equatable {
    /// Write (create or replace) a repository-relative file.
    case write(String, String)
    case delete(String)
    /// Stage everything and commit.
    case commit(String)
    /// Create a branch at HEAD and switch to it.
    case createBranch(String)
    case switchTo(String)
    /// Cherry-pick the tip commit of another branch onto HEAD.
    case cherryPickTip(branch: String)
    /// Revert the commit at HEAD.
    case revertHead
    /// Move the fixture clock forward, so later commits look `days` older/newer (staleness tests).
    case advanceDays(Int)
    /// Author the following commits as someone else ("Mine" filter tests).
    case author(name: String, email: String)
    /// Any other git command, run in the repository (`merge --ff-only`, `switch --create x origin/y`, `config` …).
    case git([String])
}

/// A fixture: how to build it, which two branches to merge, and what git is expected to report.
public struct FixtureDefinition: Sendable, Equatable {
    public let pattern: FixturePattern
    /// Branch the merge goes into (the "ours" side).
    public let targetBranch: String
    /// Branch being merged in (the "theirs" side).
    public let sourceBranch: String
    public let steps: [FixtureStep]
    /// Paths `git merge-tree` must report as conflicted, sorted.
    public let expectedConflicts: [String]
    /// What a correct resolution looks like — the contract later resolver tiers are tested against.
    public let expectedResolution: String
}

/// Branch every fixture starts on; target and source are cut from it.
public enum FixtureBranch {
    public static let base = "base"
    public static let target = "target"
    public static let source = "source"
}
