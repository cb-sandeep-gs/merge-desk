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
    public let notes: [BranchNote]

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

    public init(_ branch: BranchRecord, integrationNames: [String]) {
        name = branch.name
        presence = branch.presence
        lastCommit = branch.tip.committerDate
        author = branch.tip.authorName
        first = ComparisonCell(integrationNames.first.flatMap(branch.status(against:)))
        second = ComparisonCell(integrationNames.dropFirst().first.flatMap(branch.status(against:)))
        notes = BranchNote.notes(for: branch)
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
    public var presenceSortKey: String { presence.rawValue }
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

    public var text: String {
        switch self {
        case .integration: return "Integration"
        case .protected: return "Protected"
        case .stale: return "Stale"
        case let .merged(names): return "Merged into \(names.joined(separator: " + "))"
        case .neverPushed: return "Never pushed"
        case let .unpushed(count): return "\(count) unpushed"
        case let .toPull(count): return "\(count) to pull"
        }
    }

    /// Badge text for the narrow table column; `text` (full) goes in the tooltip and the detail pane.
    public var shortText: String {
        switch self {
        case .merged: return "Merged"
        default: return text
        }
    }

    static func notes(for branch: BranchRecord) -> [BranchNote] {
        var notes: [BranchNote] = []
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
