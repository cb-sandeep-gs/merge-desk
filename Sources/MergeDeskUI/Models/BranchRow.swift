import Foundation
import MergeDeskCore

/// One Branches-table row: display text plus plain sortable values (SwiftUI `Table` sorts by key path).
public struct BranchRow: Identifiable, Sendable, Equatable {
    /// Text for a comparison column with no data (integration branch itself, or no such integration branch).
    public static let missingValue = "—"

    public var id: String { name }
    public let name: String
    public let presence: BranchPresence
    public let lastCommit: Date
    public let author: String
    /// Ahead/behind against the first two integration branches (the table shows two comparison columns;
    /// further integration branches appear in the detail pane).
    public let first: ComparisonCell
    public let second: ComparisonCell
    /// Predicted merge into the first integration branch.
    public let merge: MergeCell
    public let notes: [BranchNote]

    /// "clean", "3 files (2 auto)", "merged", or "…" while predictions load.
    public struct MergeCell: Sendable, Equatable {
        public let state: MergeState

        public var text: String {
            switch state {
            case .pending: return "…"
            case .notApplicable: return BranchRow.missingValue
            case .alreadyMerged: return "merged"
            case .clean: return "clean"
            case let .conflicts(total, automatic):
                let files = total == 1 ? "1 file" : "\(total) files"
                return automatic > 0 ? "\(files) (\(automatic) auto)" : files
            }
        }

        public var hasConflicts: Bool {
            if case .conflicts = state { return true }
            return false
        }

        /// Conflicts that need a person first (most manual work), then automatic ones; clean and merged last.
        public var sortKey: Int {
            switch state {
            case let .conflicts(total, automatic): return Self.conflictBase + (total - automatic) * Self.manualWeight + automatic
            case .clean: return Self.cleanKey
            case .alreadyMerged: return Self.mergedKey
            case .pending, .notApplicable: return Self.unknownKey
            }
        }

        private static let manualWeight = 1_000
        private static let conflictBase = 10
        private static let cleanKey = 2
        private static let mergedKey = 1
        private static let unknownKey = 0

        init(_ prediction: BranchPrediction?, loaded: Bool) {
            guard loaded else {
                state = .pending
                return
            }
            guard let prediction else {
                state = .notApplicable
                return
            }
            guard let merge = prediction.prediction else {
                state = .alreadyMerged
                return
            }
            state = merge.isClean ? .clean : .conflicts(total: merge.conflicts.count, automatic: merge.automaticCount)
        }
    }

    public struct ComparisonCell: Sendable, Equatable {
        public let text: String
        /// Sort key: commits behind (missing sorts last), then ahead.
        public let sortKey: Int

        static let missing = ComparisonCell(text: BranchRow.missingValue, sortKey: .max)

        init(_ status: IntegrationStatus?) {
            guard let status else {
                self = .missing
                return
            }
            let counts = status.aheadBehind
            text = status.isMerged && counts.behind == 0 ? "merged" : "↑\(counts.ahead) ↓\(counts.behind)"
            // Behind dominates (it is what makes a merge hard); ahead breaks ties.
            sortKey = counts.behind * Self.behindWeight + min(counts.ahead, Self.behindWeight - 1)
        }

        private init(text: String, sortKey: Int) {
            self.text = text
            self.sortKey = sortKey
        }

        private static let behindWeight = 1_000_000
    }

    public init(_ branch: BranchRecord, integrationNames: [String], mergePrediction: BranchPrediction? = nil,
                predictionsLoaded: Bool = false, pullRequest: PullRequestInfo? = nil) {
        name = branch.name
        presence = branch.presence
        lastCommit = branch.tip.committerDate
        author = branch.tip.authorName
        first = ComparisonCell(integrationNames.first.flatMap(branch.status(against:)))
        second = ComparisonCell(integrationNames.dropFirst().first.flatMap(branch.status(against:)))
        notes = BranchNote.notes(for: branch, pullRequest: pullRequest)
        merge = branch.isIntegration ? MergeCell(nil, loaded: true) : MergeCell(mergePrediction, loaded: predictionsLoaded)
    }

    public var presenceText: String {
        switch presence {
        case .both: return "Both"
        case .local: return "Local"
        case .remote: return "Remote"
        }
    }

    public var firstSortKey: Int { first.sortKey }
    public var secondSortKey: Int { second.sortKey }
    public var mergeSortKey: Int { merge.sortKey }
    public var presenceSortKey: String { presence.rawValue }
}

/// A branch's predicted merge into the first integration branch, as shown in the table.
public enum MergeState: Sendable, Equatable {
    case pending
    case notApplicable
    case alreadyMerged
    case clean
    case conflicts(total: Int, automatic: Int)
}

/// Short labels shown as badges in the table and the detail header.
public enum BranchNote: Sendable, Equatable, Hashable {
    case integration
    case protected
    case stale
    case merged(into: [String])
    case neverPushed
    case unpushed(Int)
    case toPull(Int)
    case pullRequest(number: Int, checks: CheckSummary)

    public var text: String {
        switch self {
        case .integration: return "Integration"
        case .protected: return "Protected"
        case .stale: return "Stale"
        case let .merged(names): return "Merged into \(names.joined(separator: " + "))"
        case .neverPushed: return "Never pushed"
        case let .unpushed(count): return "\(count) unpushed"
        case let .toPull(count): return "\(count) to pull"
        case let .pullRequest(number, checks):
            switch checks {
            case .passing: return "PR #\(number) ✓"
            case .failing: return "PR #\(number) ✗"
            case .pending: return "PR #\(number) …"
            case .none: return "PR #\(number)"
            }
        }
    }

    /// Badge text for the narrow table column; `text` (full) goes in the tooltip and the detail pane.
    public var shortText: String {
        switch self {
        case .merged: return "Merged"
        default: return text
        }
    }

    static func notes(for branch: BranchRecord, pullRequest: PullRequestInfo? = nil) -> [BranchNote] {
        var notes: [BranchNote] = []
        // An open PR is the most useful fact about a branch, so it comes first.
        if let pullRequest { notes.append(.pullRequest(number: pullRequest.number, checks: pullRequest.checks)) }
        if branch.isIntegration { notes.append(.integration) }
        if branch.isProtected { notes.append(.protected) }
        if branch.isStale { notes.append(.stale) }
        if !branch.isIntegration, !branch.mergedInto.isEmpty { notes.append(.merged(into: branch.mergedInto)) }
        if branch.presence == .local { notes.append(.neverPushed) }
        if let sync = branch.localSync {
            if sync.ahead > 0 { notes.append(.unpushed(sync.ahead)) }
            if sync.behind > 0 { notes.append(.toPull(sync.behind)) }
        }
        return notes
    }
}
