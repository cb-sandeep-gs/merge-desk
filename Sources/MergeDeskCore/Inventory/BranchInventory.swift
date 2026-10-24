import Foundation

/// Where a branch exists.
public enum BranchPresence: String, Sendable, Codable, CaseIterable {
    /// Only in this clone — never pushed (or deleted on the remote).
    case local
    /// Only on a remote — never checked out here.
    case remote
    case both
}

/// An integration branch (develop, main…) resolved to the ref everything is compared with.
public struct IntegrationRef: Sendable, Equatable, Codable {
    public let name: String
    /// The ref used: the primary remote's copy when it exists (shared state), else the local branch.
    public let ref: String
    public let objectID: String
}

/// How a branch compares with one integration branch.
public struct IntegrationStatus: Sendable, Equatable, Codable {
    public let integration: String
    public let aheadBehind: AheadBehind

    /// Every commit of the branch is already in the integration branch. Also true for a branch created but
    /// never committed to — either way there is nothing left to merge.
    public var isMerged: Bool { aheadBehind.ahead == 0 }
}

/// One branch name, with its local and remote copies merged into a single row.
public struct BranchRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: String { name }

    public let name: String
    public let local: GitRef?
    /// Remote-tracking copies, primary remote first.
    public let remotes: [GitRef]
    /// The copy every comparison uses: the primary remote's tip when it exists (what the team sees), otherwise
    /// the local tip, otherwise another remote's.
    public let tip: GitRef
    public let isIntegration: Bool
    public let isProtected: Bool
    public let isActiveWork: Bool
    public let isStale: Bool
    /// Local branch vs its copy on the primary remote: ahead = unpushed commits, behind = not yet pulled.
    /// Nil unless the branch exists both locally and on the primary remote.
    public let localSync: AheadBehind?
    /// One entry per available integration branch, in config order; empty for an integration branch itself.
    public let integration: [IntegrationStatus]

    public var presence: BranchPresence {
        switch (local != nil, !remotes.isEmpty) {
        case (true, true): return .both
        case (true, false): return .local
        default: return .remote
        }
    }

    /// Integration branches this branch is fully merged into, in config order.
    public var mergedInto: [String] { integration.filter(\.isMerged).map(\.integration) }

    /// Commits only in this clone: a local-only branch, or a local copy ahead of the remote.
    public var hasUnpushedCommits: Bool {
        presence == .local || (localSync?.ahead ?? 0) > 0
    }

    public func status(against integrationName: String) -> IntegrationStatus? {
        integration.first { $0.integration == integrationName }
    }
}

/// Everything the Branches screen and `mergedesk list` show for one repository.
public struct RepositoryInventory: Sendable, Equatable, Codable {
    public let repositoryPath: String
    public let generatedAt: Date
    /// Integration branches found, in config order.
    public let integrationRefs: [IntegrationRef]
    /// Configured integration branches that exist neither locally nor on the primary remote.
    public let missingIntegrationBranches: [String]
    /// `git config user.email` in this repository — drives the "Mine" filter.
    public let currentUserEmail: String?
    /// Sorted by name.
    public let branches: [BranchRecord]

    public func branch(named name: String) -> BranchRecord? {
        branches.first { $0.name == name }
    }
}
