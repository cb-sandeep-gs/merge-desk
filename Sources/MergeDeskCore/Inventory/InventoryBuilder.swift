import Foundation

/// Builds a `RepositoryInventory` from git: lists refs, folds local and remote copies into one row per branch,
/// and computes ahead/behind against every integration branch. Read-only — it never changes the repository.
public struct InventoryBuilder: Sendable {
    /// git processes in flight at once; each comparison is ~20 ms on a large repo, so this keeps a full refresh
    /// of ~50 branches well under a second without flooding the machine.
    public static let maxConcurrentGitCommands = 8
    static let userEmailKey = "user.email"

    private let git: GitClient
    private let cache: ComparisonCache

    public init(git: GitClient = ProcessGitClient(), cache: ComparisonCache = ComparisonCache()) {
        self.git = git
        self.cache = cache
    }

    public func build(repositoryRoot: URL, config: RepoConfig, now: Date = Date()) async throws -> RepositoryInventory {
        async let refsResult = git.execute(.branches(), in: repositoryRoot)
        async let emailResult = git.execute(.configValue(Self.userEmailKey), in: repositoryRoot)
        let refs = try await refsResult
        // A missing email only disables the "Mine" filter; it must not fail the whole inventory.
        let email = (try? await emailResult) ?? nil

        let groups = Self.group(refs, primaryRemote: config.primaryRemote)
        let integrationRefs = config.integrationBranches.compactMap { name in
            groups[name].map { IntegrationRef(name: name, ref: $0.tip.fullName, objectID: $0.tip.objectID) }
        }
        let missing = config.integrationBranches.filter { groups[$0] == nil }

        let comparisons = Self.comparisons(for: groups, integrationRefs: integrationRefs, config: config)
        let results = try await aheadBehind(for: comparisons, in: repositoryRoot)

        let branches = groups.values.map { group -> BranchRecord in
            let isIntegration = config.integrationBranches.contains(group.name)
            let statuses = isIntegration ? [] : integrationRefs.compactMap { base -> IntegrationStatus? in
                results[ComparisonCache.Key(tip: group.tip.objectID, base: base.objectID)]
                    .map { IntegrationStatus(integration: base.name, aheadBehind: $0) }
            }
            let localSync = group.syncKey.flatMap { results[$0] }
            return BranchRecord(
                name: group.name,
                local: group.local,
                remotes: group.remotes,
                tip: group.tip,
                isIntegration: isIntegration,
                isProtected: config.isProtected(branch: group.name),
                isActiveWork: config.isActiveWork(branch: group.name),
                isStale: config.isStale(lastCommit: group.tip.committerDate, now: now),
                localSync: localSync,
                integration: statuses
            )
        }
        return RepositoryInventory(
            repositoryPath: repositoryRoot.path,
            generatedAt: now,
            integrationRefs: integrationRefs,
            missingIntegrationBranches: missing,
            currentUserEmail: email,
            branches: branches.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        )
    }

    // MARK: - Grouping

    /// All copies of one branch name.
    struct BranchGroup {
        let name: String
        let local: GitRef?
        /// Primary remote first, then others by remote name.
        let remotes: [GitRef]
        /// The copy on the primary remote, if any.
        let primary: GitRef?
        let tip: GitRef

        /// Local vs primary-remote comparison, when both copies exist (identical ids resolve to 0/0 without git).
        var syncKey: ComparisonCache.Key? {
            guard let local, let primary else { return nil }
            return ComparisonCache.Key(tip: local.objectID, base: primary.objectID)
        }
    }

    static func group(_ refs: [GitRef], primaryRemote: String) -> [String: BranchGroup] {
        let byName = Dictionary(grouping: refs, by: \.branchName)
        return byName.reduce(into: [:]) { groups, entry in
            let local = entry.value.first { $0.kind == .local }
            let remotes = entry.value.filter { $0.kind != .local }.sorted { lhs, rhs in
                let lhsPrimary = lhs.kind == .remote(name: primaryRemote)
                let rhsPrimary = rhs.kind == .remote(name: primaryRemote)
                return lhsPrimary != rhsPrimary ? lhsPrimary : lhs.fullName < rhs.fullName
            }
            let primary = remotes.first { $0.kind == .remote(name: primaryRemote) }
            // Shared state first (primary remote), then this clone, then any other remote.
            guard let tip = primary ?? local ?? remotes.first else { return }
            groups[entry.key] = BranchGroup(name: entry.key, local: local, remotes: remotes, primary: primary, tip: tip)
        }
    }

    // MARK: - Comparisons

    /// Unique (tip, base) commit-id pairs needed for the whole inventory.
    static func comparisons(
        for groups: [String: BranchGroup], integrationRefs: [IntegrationRef], config: RepoConfig
    ) -> [ComparisonCache.Key] {
        var keys = Set<ComparisonCache.Key>()
        for group in groups.values {
            if !config.integrationBranches.contains(group.name) {
                for base in integrationRefs {
                    keys.insert(ComparisonCache.Key(tip: group.tip.objectID, base: base.objectID))
                }
            }
            if let key = group.syncKey {
                keys.insert(key)
            }
        }
        return Array(keys)
    }

    /// Ahead/behind for every pair: identical ids are 0/0, cached pairs are reused, the rest run in parallel.
    private func aheadBehind(
        for keys: [ComparisonCache.Key], in root: URL
    ) async throws -> [ComparisonCache.Key: AheadBehind] {
        let git = self.git
        let cache = self.cache
        let values = try await boundedConcurrentMap(keys, limit: Self.maxConcurrentGitCommands) { key -> AheadBehind in
            if key.tip == key.base { return AheadBehind(ahead: 0, behind: 0) }
            if let cached = await cache.aheadBehind(tip: key.tip, base: key.base) { return cached }
            let value = try await git.execute(.aheadBehind(branch: key.tip, base: key.base), in: root)
            await cache.store(value, tip: key.tip, base: key.base)
            return value
        }
        return Dictionary(uniqueKeysWithValues: zip(keys, values))
    }
}
