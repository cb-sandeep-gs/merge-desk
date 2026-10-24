import Foundation

/// Which branches to show. Pure value logic, shared by the app's filter bar and `mergedesk list --filter`.
public struct BranchFilter: Sendable, Equatable {
    public enum Scope: String, Sendable, CaseIterable, Codable {
        case all
        /// Last commit authored by the current git user.
        case mine
        /// Active work: not an integration branch, not stale, not merged into the first integration branch.
        case active
        /// No commits for `staleDays`; integration branches excluded.
        case stale
        /// Fully merged into the first integration branch and safe to delete (not integration, not protected).
        case merged
        /// Local-only branches and local copies ahead of the remote.
        case unpushed

        public var title: String {
            switch self {
            case .all: return "All"
            case .mine: return "Mine"
            case .active: return "Active"
            case .stale: return "Stale"
            case .merged: return "Merged"
            case .unpushed: return "Unpushed"
            }
        }
    }

    public var scope: Scope
    /// Case-insensitive match on branch name or last author; empty matches everything.
    public var searchText: String
    /// Only branches starting with this prefix (e.g. `feature/`); nil = any.
    public var prefix: String?

    public init(scope: Scope = .all, searchText: String = "", prefix: String? = nil) {
        self.scope = scope
        self.searchText = searchText
        self.prefix = prefix
    }

    public func apply(to inventory: RepositoryInventory) -> [BranchRecord] {
        let firstIntegration = inventory.integrationRefs.first?.name
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return inventory.branches.filter { branch in
            matchesScope(branch, firstIntegration: firstIntegration, userEmail: inventory.currentUserEmail)
                && (prefix.map { branch.name.hasPrefix($0) } ?? true)
                && (query.isEmpty
                    || branch.name.localizedCaseInsensitiveContains(query)
                    || branch.tip.authorName.localizedCaseInsensitiveContains(query))
        }
    }

    private func matchesScope(_ branch: BranchRecord, firstIntegration: String?, userEmail: String?) -> Bool {
        let isMergedIntoFirst = firstIntegration.map { branch.mergedInto.contains($0) } ?? false
        switch scope {
        case .all:
            return true
        case .mine:
            guard let userEmail else { return false }
            return branch.tip.authorEmail.caseInsensitiveCompare(userEmail) == .orderedSame
        case .active:
            return branch.isActiveWork && !branch.isStale && !isMergedIntoFirst
        case .stale:
            return branch.isStale && !branch.isIntegration
        case .merged:
            return isMergedIntoFirst && !branch.isIntegration && !branch.isProtected
        case .unpushed:
            return branch.hasUnpushedCommits
        }
    }

    /// Branch-name prefixes worth offering as a filter (`feature/`, `bugfix/`…), most used first.
    /// Only the first path segment counts, and only when at least `minimumPrefixCount` branches share it.
    public static func prefixes(in branches: [BranchRecord], minimumPrefixCount: Int = 2) -> [String] {
        let counts = branches.reduce(into: [String: Int]()) { counts, branch in
            guard let slash = branch.name.firstIndex(of: "/") else { return }
            counts[String(branch.name[...slash]), default: 0] += 1
        }
        return counts.filter { $0.value >= minimumPrefixCount }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
    }
}

extension RepositoryInventory {
    /// The same inventory with only the branches `filter` keeps (for `--json` output and exports).
    public func filtered(by filter: BranchFilter) -> RepositoryInventory {
        RepositoryInventory(
            repositoryPath: repositoryPath,
            generatedAt: generatedAt,
            integrationRefs: integrationRefs,
            missingIntegrationBranches: missingIntegrationBranches,
            currentUserEmail: currentUserEmail,
            branches: filter.apply(to: self)
        )
    }
}
