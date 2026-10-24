import Foundation
import MergeDeskCore
import Observation

/// State for one repository's Branches screen: inventory, filter, sort, selection and the detail pane.
@MainActor
@Observable
public final class RepositoryModel {
    public let repository: RegisteredRepository

    public private(set) var inventoryState: LoadState<RepositoryInventory> = .idle
    public private(set) var detailState: LoadState<BranchDetail> = .idle
    /// Config warnings (e.g. unknown keys) to show above the table.
    public private(set) var configWarnings: [String] = []

    public var filter = BranchFilter() {
        didSet { rebuildRows() }
    }
    public var sortOrder: [KeyPathComparator<BranchRow>] = [KeyPathComparator(\BranchRow.lastCommit, order: .reverse)] {
        didSet { rebuildRows() }
    }
    /// Selected branch name; selecting loads its detail.
    public var selectedBranch: String? {
        didSet {
            guard selectedBranch != oldValue else { return }
            loadDetail()
        }
    }

    /// Filtered and sorted rows for the table.
    public private(set) var rows: [BranchRow] = []

    private let git: GitClient
    private let cache = ComparisonCache()
    private var refreshTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?

    public init(repository: RegisteredRepository, git: GitClient = ProcessGitClient()) {
        self.repository = repository
        self.git = git
    }

    // MARK: - Derived

    public var inventory: RepositoryInventory? { inventoryState.value }
    public var integrationNames: [String] { inventory?.integrationRefs.map(\.name) ?? [] }
    public var availablePrefixes: [String] { inventory.map { BranchFilter.prefixes(in: $0.branches) } ?? [] }
    public var totalBranchCount: Int { inventory?.branches.count ?? 0 }

    // MARK: - Actions

    /// Reloads config and inventory. A refresh in flight is replaced, never doubled. Keeps showing the previous
    /// inventory until the new one arrives (only the first load shows a spinner).
    public func refresh(now: Date = Date()) {
        refreshTask?.cancel()
        if inventoryState.value == nil { inventoryState = .loading }
        let root = repository.url
        let builder = InventoryBuilder(git: git, cache: cache)
        refreshTask = Task { [weak self] in
            do {
                let loaded = try ConfigLoader.load(repositoryRoot: root)
                let inventory = try await builder.build(repositoryRoot: root, config: loaded.config, now: now)
                guard !Task.isCancelled else { return }
                self?.apply(inventory, warnings: loaded.warnings.map(\.description))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.inventoryState = .failed(ErrorText.message(error))
            }
        }
    }

    /// Waits for the current refresh (tests and the CLI-style "refresh then read" flow).
    public func waitForRefresh() async {
        await refreshTask?.value
    }

    public func waitForDetail() async {
        await detailTask?.value
    }

    private func apply(_ inventory: RepositoryInventory, warnings: [String]) {
        configWarnings = warnings
        inventoryState = .loaded(inventory)
        rebuildRows()
        // Keep the selection if the branch still exists; reload its detail (its tip may have moved).
        if let selected = selectedBranch {
            if inventory.branch(named: selected) == nil {
                selectedBranch = nil
            } else {
                loadDetail()
            }
        }
    }

    private func rebuildRows() {
        guard let inventory else {
            rows = []
            return
        }
        let names = integrationNames
        rows = filter.apply(to: inventory)
            .map { BranchRow($0, integrationNames: names) }
            .sorted(using: sortOrder)
    }

    private func loadDetail() {
        detailTask?.cancel()
        guard let name = selectedBranch, let inventory else {
            detailState = .idle
            return
        }
        detailState = .loading
        let loader = BranchDetailLoader(git: git, cache: cache)
        let root = repository.url
        detailTask = Task { [weak self] in
            do {
                let detail = try await loader.load(branchNamed: name, from: inventory, repositoryRoot: root)
                guard !Task.isCancelled else { return }
                self?.detailState = .loaded(detail)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.detailState = .failed(ErrorText.message(error))
            }
        }
    }
}
