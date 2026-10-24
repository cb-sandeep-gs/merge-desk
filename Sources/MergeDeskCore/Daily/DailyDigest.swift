import Foundation

/// A conflict between two named things, identified by names (not commit ids) so "new since yesterday" means a
/// pair that didn't conflict last run, even if both branches moved.
public struct ConflictKey: Sendable, Hashable, Codable, Comparable {
    public enum Kind: String, Sendable, Codable {
        /// `branch` merged into integration branch `other`.
        case integration
        /// Two active branches.
        case pair
    }

    public let kind: Kind
    public let branch: String
    public let other: String

    public static func < (lhs: ConflictKey, rhs: ConflictKey) -> Bool {
        (lhs.kind.rawValue, lhs.branch, lhs.other) < (rhs.kind.rawValue, rhs.branch, rhs.other)
    }

    public var description: String {
        switch kind {
        case .integration: return "\(branch) → \(other)"
        case .pair: return "\(branch) ↔ \(other)"
        }
    }
}

/// One conflict line in the digest.
public struct DigestConflict: Sendable, Equatable, Codable, Identifiable {
    public var id: ConflictKey { key }
    public let key: ConflictKey
    public let fileCount: Int
    public let automaticCount: Int
    /// Up to `DailyDigest.filePreviewCount` paths, for a quick look.
    public let files: [String]
}

/// A branch with a number attached (commits behind, days idle).
public struct DigestBranch: Sendable, Equatable, Codable, Identifiable {
    public var id: String { branch }
    public let branch: String
    public let count: Int
}

/// What happened in fetching before the run.
public enum FetchOutcome: Sendable, Equatable, Codable {
    case fetched
    case skipped
    case failed(String)
}

/// The morning report for one repository. Built from the current run and the previous run's snapshot.
public struct DailyDigest: Sendable, Equatable, Codable {
    public static let filePreviewCount = 5

    public let repositoryPath: String
    public let generatedAt: Date
    public let fetch: FetchOutcome
    /// Integration branches compared against, in config order.
    public let integrationBranches: [String]
    /// Whether a previous run existed to compare with ("new" lists are empty on the first run).
    public let hasPreviousRun: Bool

    /// Conflicts that didn't exist last run.
    public let newConflicts: [DigestConflict]
    /// Conflicts from last run that are gone.
    public let resolvedConflicts: [ConflictKey]
    /// Every current conflict with an integration branch.
    public let integrationConflicts: [DigestConflict]
    /// Every current conflict between active branches, most files first.
    public let pairConflicts: [DigestConflict]
    /// The current git user's active (not stale) branches that conflict with, or have drifted from, the first
    /// integration branch. Stale branches are listed under `stale` instead, so this stays a short to-do list.
    public let rebaseToday: [String]
    /// Active branches more than `driftBehindThreshold` commits behind the first integration branch.
    public let drifting: [DigestBranch]
    /// Stale, unmerged branches (days since last commit).
    public let stale: [DigestBranch]
    /// Fully merged into the first integration branch: safe to delete.
    public let mergedNotDeleted: [String]
    public let stats: PredictionStats

    public var isQuiet: Bool { newConflicts.isEmpty && rebaseToday.isEmpty }
}

/// Everything a run produced, saved so the next run can say what changed.
public struct DailySnapshot: Sendable, Equatable, Codable {
    public let inventory: RepositoryInventory
    public let predictions: PredictionReport

    /// Current conflicts, keyed by names.
    public var conflicts: [ConflictKey: DigestConflict] {
        var result: [ConflictKey: DigestConflict] = [:]
        for integration in predictions.integration {
            for branch in integration.conflicting {
                guard let prediction = branch.prediction else { continue }
                let key = ConflictKey(kind: .integration, branch: branch.branch, other: integration.integration)
                result[key] = DigestConflict(key: key, prediction: prediction)
            }
        }
        for pair in predictions.matrix?.conflictingPairs ?? [] {
            let key = ConflictKey(kind: .pair, branch: pair.first, other: pair.second)
            result[key] = DigestConflict(key: key, prediction: pair.prediction)
        }
        return result
    }
}

extension DigestConflict {
    init(key: ConflictKey, prediction: MergePrediction) {
        self.init(key: key, fileCount: prediction.conflicts.count, automaticCount: prediction.automaticCount,
                  files: prediction.conflicts.prefix(DailyDigest.filePreviewCount).map(\.path))
    }
}

/// Builds the digest — pure, so every rule is unit-testable.
public enum DigestBuilder {
    private static let secondsPerDay: TimeInterval = 86_400

    public static func build(
        current: DailySnapshot, previous: DailySnapshot?, config: RepoConfig, fetch: FetchOutcome
    ) -> DailyDigest {
        let inventory = current.inventory
        let now = inventory.generatedAt
        let conflicts = current.conflicts
        let previousKeys = Set(previous?.conflicts.keys ?? [:].keys)
        let firstIntegration = inventory.integrationRefs.first?.name

        let newConflicts = previous == nil ? [] : conflicts.filter { !previousKeys.contains($0.key) }.values.sorted { $0.key < $1.key }
        let resolved = previousKeys.subtracting(conflicts.keys).sorted()
        let byFiles: (DigestConflict, DigestConflict) -> Bool = { lhs, rhs in
            lhs.fileCount != rhs.fileCount ? lhs.fileCount > rhs.fileCount : lhs.key < rhs.key
        }

        let active = inventory.branches.filter { $0.isActiveWork && !$0.isIntegration }
        let drifting = firstIntegration.map { base in
            active.compactMap { branch -> DigestBranch? in
                guard let status = branch.status(against: base), !status.isMerged,
                      status.aheadBehind.behind > config.driftBehindThreshold else { return nil }
                return DigestBranch(branch: branch.name, count: status.aheadBehind.behind)
            }
            .sorted { $0.count > $1.count }
        } ?? []

        let mine = Set(BranchFilter(scope: .mine).apply(to: inventory).filter { !$0.isStale && !$0.isIntegration }.map(\.name))
        let conflictingWithFirst = Set(conflicts.keys.filter { $0.kind == .integration && $0.other == firstIntegration }.map(\.branch))
        let driftingNames = Set(drifting.map(\.branch))
        let rebaseToday = mine.filter { conflictingWithFirst.contains($0) || driftingNames.contains($0) }.sorted()

        return DailyDigest(
            repositoryPath: inventory.repositoryPath,
            generatedAt: now,
            fetch: fetch,
            integrationBranches: inventory.integrationRefs.map(\.name),
            hasPreviousRun: previous != nil,
            newConflicts: newConflicts,
            resolvedConflicts: resolved,
            integrationConflicts: conflicts.values.filter { $0.key.kind == .integration }.sorted(by: byFiles),
            pairConflicts: conflicts.values.filter { $0.key.kind == .pair }.sorted(by: byFiles),
            rebaseToday: rebaseToday,
            drifting: drifting,
            stale: BranchFilter(scope: .stale).apply(to: inventory)
                .filter { branch in branch.mergedInto.isEmpty }
                .map { DigestBranch(branch: $0.name, count: Int(now.timeIntervalSince($0.tip.committerDate) / secondsPerDay)) }
                .sorted { $0.count > $1.count },
            mergedNotDeleted: BranchFilter(scope: .merged).apply(to: inventory).map(\.name),
            stats: current.predictions.stats
        )
    }
}
