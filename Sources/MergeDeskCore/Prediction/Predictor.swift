import Foundation

/// Predicts merges with `git merge-tree --write-tree`: computed in the object store, so no worktree, index or ref
/// is touched. Read-only.
public struct Predictor: Sendable {
    /// The matrix grows with the square of its size; 40 branches = 780 pairs (~15 s cold on a large repo, instant
    /// warm). Older active branches beyond this are listed as omitted.
    public static let maxMatrixBranches = 40

    public enum Scope: Sendable {
        /// Every unmerged branch against every integration branch.
        case integration
        /// Integration plus the branch × branch matrix of active work.
        case integrationAndMatrix
    }

    private let git: GitClient
    private let store: PredictionStore

    public init(git: GitClient = ProcessGitClient(), store: PredictionStore = PredictionStore(fileURL: nil)) {
        self.git = git
        self.store = store
    }

    public func predict(
        inventory: RepositoryInventory, config: RepoConfig, repositoryRoot: URL, scope: Scope, now: Date = Date()
    ) async throws -> PredictionReport {
        let started = Date()
        let integrationJobs = Self.integrationJobs(inventory)
        let matrixSelection = scope == .integrationAndMatrix ? Self.matrixSelection(inventory) : nil
        let matrixJobs = matrixSelection.map { Self.matrixJobs($0.branches, inventory: inventory) } ?? []

        let counter = CacheCounter()
        let outcomes = try await outcomes(for: integrationJobs.map(\.pair) + matrixJobs.map(\.pair),
                                          root: repositoryRoot, now: now, counter: counter)
        try await store.save()

        let integration = inventory.integrationRefs.map { base in
            IntegrationPredictions(integration: base.name, branches: integrationJobs.filter { $0.integration == base.name }.map { job in
                BranchPrediction(branch: job.branch, prediction: job.isMerged ? nil : outcomes[job.pair].map {
                    MergePrediction(targetID: job.pair.target, sourceID: job.pair.source, outcome: $0, config: config)
                })
            })
        }
        let matrix = matrixSelection.map { selection in
            MatrixPredictions(
                branches: selection.branches,
                conflictingPairs: matrixJobs.compactMap { job -> PairPrediction? in
                    guard let outcome = outcomes[job.pair], !outcome.isClean else { return nil }
                    return PairPrediction(first: job.first, second: job.second, prediction: MergePrediction(
                        targetID: job.pair.target, sourceID: job.pair.source, outcome: outcome, config: config))
                }
                .sorted { lhs, rhs in
                    lhs.prediction.conflicts.count != rhs.prediction.conflicts.count
                        ? lhs.prediction.conflicts.count > rhs.prediction.conflicts.count
                        : lhs.id < rhs.id
                },
                omittedBranches: selection.omitted
            )
        }
        let (computed, cached) = await counter.totals
        return PredictionReport(
            repositoryPath: repositoryRoot.path,
            generatedAt: now,
            integration: integration,
            matrix: matrix,
            stats: PredictionStats(mergesComputed: computed, mergesFromCache: cached,
                                   durationSeconds: Date().timeIntervalSince(started))
        )
    }

    // MARK: - Jobs

    /// A merge to predict: `source` merged into `target` (commit ids).
    struct MergePair: Hashable, Sendable {
        let target: String
        let source: String
    }

    struct IntegrationJob: Sendable {
        let integration: String
        let branch: String
        let pair: MergePair
        /// Already merged: nothing to predict.
        let isMerged: Bool
    }

    struct MatrixJob: Sendable {
        let first: String
        let second: String
        let pair: MergePair
    }

    static func integrationJobs(_ inventory: RepositoryInventory) -> [IntegrationJob] {
        inventory.integrationRefs.flatMap { base in
            inventory.branches.filter { !$0.isIntegration }.compactMap { branch -> IntegrationJob? in
                guard let status = branch.status(against: base.name) else { return nil }
                return IntegrationJob(integration: base.name, branch: branch.name,
                                      pair: MergePair(target: base.objectID, source: branch.tip.objectID),
                                      isMerged: status.isMerged)
            }
        }
    }

    /// Active, recent, unmerged work — newest first, capped at `maxMatrixBranches`.
    static func matrixSelection(_ inventory: RepositoryInventory) -> (branches: [String], omitted: [String]) {
        let firstIntegration = inventory.integrationRefs.first?.name
        let candidates = inventory.branches
            .filter { branch in
                branch.isActiveWork && !branch.isStale && !branch.isIntegration
                    && !(firstIntegration.map { branch.mergedInto.contains($0) } ?? false)
            }
            .sorted { $0.tip.committerDate > $1.tip.committerDate }
            .map(\.name)
        return (Array(candidates.prefix(maxMatrixBranches)), Array(candidates.dropFirst(maxMatrixBranches)))
    }

    static func matrixJobs(_ names: [String], inventory: RepositoryInventory) -> [MatrixJob] {
        let tips = Dictionary(uniqueKeysWithValues: inventory.branches.map { ($0.name, $0.tip.objectID) })
        let sorted = names.sorted()
        var jobs: [MatrixJob] = []
        for (index, first) in sorted.enumerated() {
            for second in sorted[(index + 1)...] {
                guard let firstID = tips[first], let secondID = tips[second], firstID != secondID else { continue }
                jobs.append(MatrixJob(first: first, second: second, pair: MergePair(target: firstID, source: secondID)))
            }
        }
        return jobs
    }

    // MARK: - Running merge-tree

    private func outcomes(
        for pairs: [MergePair], root: URL, now: Date, counter: CacheCounter
    ) async throws -> [MergePair: MergeOutcome] {
        let unique = Array(Set(pairs))
        let git = self.git
        let store = self.store
        let values = try await boundedConcurrentMap(unique, limit: InventoryBuilder.maxConcurrentGitCommands) { pair in
            if let cached = await store.outcome(pair.target, pair.source, now: now) {
                await counter.hit()
                return cached
            }
            let result = try await git.execute(.mergeTree(target: pair.target, source: pair.source), in: root)
            let outcome = MergeOutcome(result)
            await store.store(outcome, pair.target, pair.source, now: now)
            await counter.miss()
            return outcome
        }
        return Dictionary(uniqueKeysWithValues: zip(unique, values))
    }
}

/// Counts cache hits and git runs across concurrent tasks.
private actor CacheCounter {
    private var computed = 0
    private var cached = 0

    func hit() { cached += 1 }
    func miss() { computed += 1 }
    var totals: (Int, Int) { (computed, cached) }
}
