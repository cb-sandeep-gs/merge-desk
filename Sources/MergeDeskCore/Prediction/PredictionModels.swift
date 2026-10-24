import Foundation

/// What `git merge-tree` reported for one pair of commits — independent of any config, so it can be cached by
/// commit ids forever.
public struct MergeOutcome: Sendable, Equatable, Codable {
    public let treeID: String
    /// Conflicted paths in git's order.
    public let conflictedPaths: [String]
    /// Conflict kinds per path, e.g. `CONFLICT (contents)`, `CONFLICT (modify/delete)`.
    public let kindsByPath: [String: [String]]

    public var isClean: Bool { conflictedPaths.isEmpty }

    public init(_ result: MergeTreeResult) {
        treeID = result.treeID
        conflictedPaths = result.conflictedPaths
        var kinds: [String: [String]] = [:]
        for message in result.messages where message.type.hasPrefix(Self.conflictPrefix) {
            for path in message.paths where !(kinds[path]?.contains(message.type) ?? false) {
                kinds[path, default: []].append(message.type)
            }
        }
        kindsByPath = kinds
    }

    /// git's informational messages also include "Auto-merging x"; only CONFLICT ones describe a conflict.
    private static let conflictPrefix = "CONFLICT"
}

/// How a predicted conflict is expected to be resolved, from the repository's file classes (PLAN.md §6.4).
public enum ResolutionRoute: Sendable, Equatable, Hashable, Codable {
    /// A Tier-1 file rule handles it (`escalate` means a person, by rule).
    case rule(FileStrategy)
    /// No file rule matches: replayed resolutions and the history engine (MD-4/MD-5) or a person.
    case historyOrPerson

    /// Resolved without a person by a deterministic file rule.
    public var isAutomatic: Bool {
        if case let .rule(strategy) = self { return strategy != .escalate }
        return false
    }

    public var label: String {
        switch self {
        case let .rule(strategy): return strategy == .escalate ? "person (rule)" : strategy.rawValue
        case .historyOrPerson: return "history / person"
        }
    }
}

/// One conflicting file in a predicted merge.
public struct PredictedConflict: Sendable, Equatable, Codable, Identifiable {
    public var id: String { path }
    public let path: String
    public let kinds: [String]
    public let route: ResolutionRoute
}

/// A predicted merge of `source` into `target`.
public struct MergePrediction: Sendable, Equatable, Codable {
    public let targetID: String
    public let sourceID: String
    public let conflicts: [PredictedConflict]

    public var isClean: Bool { conflicts.isEmpty }
    public var automaticCount: Int { conflicts.filter(\.route.isAutomatic).count }
    /// Conflicts that will need the history engine or a person.
    public var manualCount: Int { conflicts.count - automaticCount }

    public init(targetID: String, sourceID: String, outcome: MergeOutcome, config: RepoConfig) {
        self.targetID = targetID
        self.sourceID = sourceID
        conflicts = outcome.conflictedPaths.map { path in
            PredictedConflict(
                path: path,
                kinds: outcome.kindsByPath[path] ?? [],
                route: config.fileClass(for: path).map { .rule($0.strategy) } ?? .historyOrPerson
            )
        }
    }

    /// "clean", "3 conflicts (2 automatic)".
    public var summary: String {
        guard !isClean else { return "clean" }
        let noun = conflicts.count == 1 ? "conflict" : "conflicts"
        return automaticCount > 0 ? "\(conflicts.count) \(noun) (\(automaticCount) automatic)" : "\(conflicts.count) \(noun)"
    }
}

/// A branch's predicted merge into one integration branch.
public struct BranchPrediction: Sendable, Equatable, Codable {
    public let branch: String
    /// Nil when there's nothing to merge (already merged), see `isAlreadyMerged`.
    public let prediction: MergePrediction?

    public var isAlreadyMerged: Bool { prediction == nil }
    public var hasConflicts: Bool { !(prediction?.isClean ?? true) }
}

/// Every branch predicted against one integration branch.
public struct IntegrationPredictions: Sendable, Equatable, Codable {
    public let integration: String
    public let branches: [BranchPrediction]

    public func prediction(for branch: String) -> BranchPrediction? {
        branches.first { $0.branch == branch }
    }

    public var conflicting: [BranchPrediction] { branches.filter(\.hasConflicts) }
}

/// Two active branches merged with each other.
public struct PairPrediction: Sendable, Equatable, Codable, Identifiable {
    public var id: String { "\(first)\u{0}\(second)" }
    /// `first` < `second` by name, so a pair has one identity.
    public let first: String
    public let second: String
    public let prediction: MergePrediction

    public func involves(_ branch: String) -> Bool { first == branch || second == branch }
    public func other(than branch: String) -> String { first == branch ? second : first }
}

/// The branch × branch matrix for active work.
public struct MatrixPredictions: Sendable, Equatable, Codable {
    /// Branches in the matrix, most recent commit first.
    public let branches: [String]
    /// Only pairs that conflict (clean pairs are implied), most conflicts first.
    public let conflictingPairs: [PairPrediction]
    /// Active branches left out because of `Predictor.maxMatrixBranches`.
    public let omittedBranches: [String]

    public func pair(_ first: String, _ second: String) -> PairPrediction? {
        let (low, high) = first < second ? (first, second) : (second, first)
        return conflictingPairs.first { $0.first == low && $0.second == high }
    }
}

/// Cost of a prediction run, for the status line and logs.
public struct PredictionStats: Sendable, Equatable, Codable {
    public let mergesComputed: Int
    public let mergesFromCache: Int
    public let durationSeconds: Double
}

/// Everything predicted for one repository at one moment.
public struct PredictionReport: Sendable, Equatable, Codable {
    public let repositoryPath: String
    public let generatedAt: Date
    /// One entry per available integration branch, in config order.
    public let integration: [IntegrationPredictions]
    /// Nil when the matrix wasn't requested.
    public let matrix: MatrixPredictions?
    public let stats: PredictionStats

    public func integration(named name: String) -> IntegrationPredictions? {
        integration.first { $0.integration == name }
    }
}
