import Foundation

/// Another active branch that changed some of the same files since the two branches diverged.
public struct BranchOverlap: Sendable, Equatable, Codable, Identifiable {
    public var id: String { branch }
    public let branch: String
    public let sharedFiles: [String]
}

/// The detail pane / `mergedesk show`: what a branch contains relative to the first integration branch.
public struct BranchDetail: Sendable, Equatable, Codable {
    public let branch: BranchRecord
    /// What commits and files are measured against; nil when no integration branch exists.
    public let base: IntegrationRef?
    /// Newest first.
    public let uniqueCommits: [CommitSummary]
    /// More commits exist than `uniqueCommits` holds.
    public let uniqueCommitsTruncated: Bool
    /// Files changed since the branch forked from `base`, sorted.
    public let changedFiles: [String]
    /// Other active, unmerged branches that changed the same files since diverging from this one (measured from
    /// each pair's own merge base, so commits both branches already share don't count) — most shared files first.
    public let overlaps: [BranchOverlap]
}

public enum BranchDetailError: Error, Equatable, CustomStringConvertible {
    case unknownBranch(String)

    public var description: String {
        switch self {
        case let .unknownBranch(name): return "No branch named '\(name)' (run `mergedesk list` to see them)"
        }
    }
}

/// Loads `BranchDetail` on demand (it costs one `git diff` per active branch the first time; cached after).
public struct BranchDetailLoader: Sendable {
    /// Enough to read a branch's story; very long histories are cut, and the result says so.
    public static let defaultMaxCommits = 200

    private let git: GitClient
    private let cache: ComparisonCache

    public init(git: GitClient = ProcessGitClient(), cache: ComparisonCache = ComparisonCache()) {
        self.git = git
        self.cache = cache
    }

    public func load(
        branchNamed name: String,
        from inventory: RepositoryInventory,
        repositoryRoot: URL,
        maxCommits: Int = BranchDetailLoader.defaultMaxCommits
    ) async throws -> BranchDetail {
        guard let branch = inventory.branch(named: name) else { throw BranchDetailError.unknownBranch(name) }
        // An integration branch is measured against the next one (develop against main), not against itself.
        guard let base = inventory.integrationRefs.first(where: { $0.name != branch.name }) else {
            return BranchDetail(branch: branch, base: nil, uniqueCommits: [], uniqueCommitsTruncated: false,
                                changedFiles: [], overlaps: [])
        }

        // Ask for one extra commit to know whether the list was cut.
        let commits = try await git.execute(
            .commits(from: base.objectID, to: branch.tip.objectID, maxCount: maxCommits + 1), in: repositoryRoot
        )
        let files = try await changedFiles(tip: branch.tip.objectID, base: base.objectID, in: repositoryRoot)
        let overlaps = try await overlaps(of: branch, base: base, inventory: inventory, in: repositoryRoot)
        return BranchDetail(
            branch: branch,
            base: base,
            uniqueCommits: Array(commits.prefix(maxCommits)),
            uniqueCommitsTruncated: commits.count > maxCommits,
            changedFiles: files,
            overlaps: overlaps
        )
    }

    /// Active, unmerged, non-integration branches other than `branch` that changed a file `branch` also changed
    /// since the two diverged. Each pair is measured from its own merge base: branches that share commits not yet
    /// in the integration branch would otherwise all "overlap" on those shared commits.
    private func overlaps(
        of branch: BranchRecord, base: IntegrationRef, inventory: RepositoryInventory, in root: URL
    ) async throws -> [BranchOverlap] {
        let candidates = inventory.branches.filter { other in
            other.name != branch.name && other.isActiveWork && !other.isIntegration
                && !(other.status(against: base.name)?.isMerged ?? true)
        }
        let loader = self
        let tip = branch.tip.objectID
        let results = try await boundedConcurrentMap(candidates, limit: InventoryBuilder.maxConcurrentGitCommands) { other in
            // `x...y` diffs from merge-base(x, y), so these are each side's own changes since they diverged.
            let ours = try await loader.changedFiles(tip: tip, base: other.tip.objectID, in: root)
            let theirs = Set(try await loader.changedFiles(tip: other.tip.objectID, base: tip, in: root))
            return BranchOverlap(branch: other.name, sharedFiles: ours.filter(theirs.contains))
        }
        return results.filter { !$0.sharedFiles.isEmpty }
            .sorted { $0.sharedFiles.count != $1.sharedFiles.count ? $0.sharedFiles.count > $1.sharedFiles.count : $0.branch < $1.branch }
    }

    private func changedFiles(tip: String, base: String, in root: URL) async throws -> [String] {
        if let cached = await cache.changedFiles(tip: tip, base: base) { return cached }
        let files = try await git.execute(.changedFiles(base: base, tip: tip), in: root)
        await cache.store(changedFiles: files, tip: tip, base: base)
        return files
    }
}
