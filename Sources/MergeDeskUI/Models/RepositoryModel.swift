import Foundation
import MergeDeskCore
import Observation

/// What the middle pane shows for a repository.
public enum ContentMode: String, CaseIterable, Sendable {
    case branches
    /// The guided Merge tab.
    case merge
    case matrix
    case digest
    /// History of merge sessions.
    case merges

    public var title: String {
        switch self {
        case .branches: return "Branches"
        case .merge: return "Merge"
        case .matrix: return "Conflict Matrix"
        case .digest: return "Daily Digest"
        case .merges: return "History"
        }
    }
}

/// State for one repository: inventory, predictions, matrix, digest, filter, sort, selection and the detail pane.
@MainActor
@Observable
public final class RepositoryModel {
    public let repository: RegisteredRepository

    public private(set) var inventoryState: LoadState<RepositoryInventory> = .idle
    /// Every branch vs every integration branch; follows each inventory load.
    public private(set) var predictionState: LoadState<PredictionReport> = .idle
    /// Integration + branch × branch; computed when the matrix is first shown.
    public private(set) var matrixState: LoadState<PredictionReport> = .idle
    public private(set) var detailState: LoadState<BranchDetail> = .idle
    /// Latest saved digest (from the scheduled run or "Run Now").
    public private(set) var digest: DailyDigest?
    public private(set) var isRunningDaily = false
    public private(set) var dailyError: String?
    /// Config warnings (e.g. unknown keys) to show above the table.
    public private(set) var configWarnings: [String] = []
    /// Merge sessions for this repository.
    public let sessions: SessionsModel
    /// The guided Merge tab.
    public private(set) var mergeFlow: MergeFlowModel!
    /// Open pull requests by head branch (only when the GitHub CLI is installed and signed in).
    public private(set) var pullRequests: [String: PullRequestInfo] = [:]

    /// Remembered per repository between launches.
    public var contentMode: ContentMode = .branches {
        didSet {
            defaults.set(contentMode.rawValue, forKey: contentModeKey)
            if contentMode == .matrix, matrixState.value == nil, !matrixState.isLoading { loadMatrix() }
        }
    }
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
    /// Selected matrix cell.
    public var selectedPair: PairPrediction?

    /// Filtered and sorted rows for the table.
    public private(set) var rows: [BranchRow] = []

    private let git: GitClient
    private let paths: SupportPaths
    @ObservationIgnored private let defaults: PreferenceStore
    private var contentModeKey: String { "\(Self.contentModeKeyPrefix)\(repository.id.uuidString)" }
    static let contentModeKeyPrefix = "contentMode."
    private let cache = ComparisonCache()
    private let predictionStore: PredictionStore
    private let github: GitHubCLI
    /// Shared with `sessions`, which always merges with the latest loaded config.
    @ObservationIgnored private let configHolder = ConfigHolder()
    private var config: RepoConfig {
        get { configHolder.value }
        set { configHolder.value = newValue }
    }
    private var pullRequestTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var predictionTask: Task<Void, Never>?
    private var matrixTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var dailyTask: Task<Void, Never>?

    public init(repository: RegisteredRepository, git: GitClient = ProcessGitClient(), paths: SupportPaths = SupportPaths(),
                defaults: PreferenceStore = UserDefaults.standard, github: GitHubCLI = GitHubCLI()) {
        self.repository = repository
        self.git = git
        self.paths = paths
        self.defaults = defaults
        self.github = github
        let holder = configHolder
        self.sessions = SessionsModel(repository: repository, git: git, paths: paths, github: github) { holder.value }
        self.contentMode = defaults.string(forKey: "\(Self.contentModeKeyPrefix)\(repository.id.uuidString)")
            .flatMap(ContentMode.init(rawValue:)) ?? .branches
        self.predictionStore = PredictionStore(paths: paths, repositoryRoot: repository.url)
        self.digest = DailyRunner.latestDigest(repositoryRoot: repository.url, paths: paths)
        sessions.onBranchesChanged = { [weak self] in self?.refresh() }
        mergeFlow = MergeFlowModel(sessions: sessions, git: git) { [weak self] in self?.inventory }
    }

    // MARK: - Derived

    public var inventory: RepositoryInventory? { inventoryState.value }
    public var predictions: PredictionReport? { predictionState.value }
    public var integrationNames: [String] { inventory?.integrationRefs.map(\.name) ?? [] }
    public var availablePrefixes: [String] { inventory.map { BranchFilter.prefixes(in: $0.branches) } ?? [] }
    public var totalBranchCount: Int { inventory?.branches.count ?? 0 }

    /// Predicted merges of the selected branch into each integration branch.
    public var selectedBranchPredictions: [(integration: String, prediction: BranchPrediction)] {
        guard let name = selectedBranch, let predictions else { return [] }
        return predictions.integration.compactMap { integration in
            integration.prediction(for: name).map { (integration.integration, $0) }
        }
    }

    // MARK: - Actions

    /// The toolbar's Merge…: go to the Merge tab with the selected branch as the one to merge from.
    public func startMergeFromSelection() {
        if mergeFlow.step == .choose, let selectedBranch { mergeFlow.from = selectedBranch }
        contentMode = .merge
    }

    /// Reloads config and inventory, then predictions. A refresh in flight is replaced, never doubled. Keeps
    /// showing the previous data until the new data arrives (only the first load shows a spinner).
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
                self?.apply(inventory, config: loaded.config, warnings: loaded.warnings.map(\.description))
                await self?.predictionTask?.value
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.inventoryState = .failed(ErrorText.message(error))
            }
        }
    }

    /// Waits for the current refresh and the predictions it started.
    public func waitForRefresh() async {
        await refreshTask?.value
        await predictionTask?.value
    }

    public func waitForDetail() async { await detailTask?.value }
    public func waitForMatrix() async { await matrixTask?.value }
    public func waitForDaily() async { await dailyTask?.value }

    /// Computes the branch × branch matrix (seconds on a large repo the first time, then cached on disk).
    public func loadMatrix() {
        guard let inventory else { return }
        matrixTask?.cancel()
        matrixState = .loading
        let predictor = Predictor(git: git, store: predictionStore)
        let config = self.config
        let root = repository.url
        matrixTask = Task { [weak self] in
            do {
                let report = try await predictor.predict(inventory: inventory, config: config, repositoryRoot: root,
                                                         scope: .integrationAndMatrix, now: inventory.generatedAt)
                guard !Task.isCancelled else { return }
                self?.matrixState = .loaded(report)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.matrixState = .failed(ErrorText.message(error))
            }
        }
    }

    /// Runs the daily job now: fetch, predict, write the digest; then reloads everything. No notification —
    /// the result is on screen.
    public func runDaily(fetch: Bool = true, now: Date = Date()) {
        guard !isRunningDaily else { return }
        isRunningDaily = true
        dailyError = nil
        let runner = DailyRunner(git: git, paths: paths, notifier: SilentNotifier())
        let root = repository.url
        dailyTask = Task { [weak self] in
            do {
                let result = try await runner.run(repositoryRoot: root, fetch: fetch, now: now)
                self?.digest = result.digest
            } catch {
                self?.dailyError = ErrorText.message(error)
            }
            self?.isRunningDaily = false
            // Fetching may have moved branches: show the new state everywhere.
            self?.matrixState = .idle
            self?.refresh(now: now)
            await self?.waitForRefresh()
            if self?.contentMode == .matrix { self?.loadMatrix() }
        }
    }

    // MARK: - Private

    private func apply(_ inventory: RepositoryInventory, config: RepoConfig, warnings: [String]) {
        self.config = config
        configWarnings = warnings
        inventoryState = .loaded(inventory)
        rebuildRows()
        loadPredictions(inventory)
        loadPullRequests()
        if contentMode == .matrix { loadMatrix() } else { matrixState = .idle }
        // Keep the selection if the branch still exists; reload its detail (its tip may have moved).
        if let selected = selectedBranch {
            if inventory.branch(named: selected) == nil {
                selectedBranch = nil
            } else {
                loadDetail()
            }
        }
    }

    /// Best effort: without `gh` (or offline) the PR badges simply don't appear.
    private func loadPullRequests() {
        pullRequestTask?.cancel()
        let github = self.github
        let root = repository.url
        pullRequestTask = Task { [weak self] in
            guard await github.isAvailable(in: root), let list = try? await github.openPullRequests(in: root),
                  !Task.isCancelled else { return }
            self?.pullRequests = Dictionary(list.map { ($0.headRefName, $0) }, uniquingKeysWith: { first, _ in first })
            self?.rebuildRows()
        }
    }

    private func loadPredictions(_ inventory: RepositoryInventory) {
        predictionTask?.cancel()
        if predictionState.value == nil { predictionState = .loading }
        let predictor = Predictor(git: git, store: predictionStore)
        let config = self.config
        let root = repository.url
        predictionTask = Task { [weak self] in
            do {
                let report = try await predictor.predict(inventory: inventory, config: config, repositoryRoot: root,
                                                         scope: .integration, now: inventory.generatedAt)
                guard !Task.isCancelled else { return }
                self?.predictionState = .loaded(report)
                self?.rebuildRows()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.predictionState = .failed(ErrorText.message(error))
            }
        }
    }

    private func rebuildRows() {
        guard let inventory else {
            rows = []
            return
        }
        let names = integrationNames
        let firstIntegration = predictions.flatMap { report in names.first.flatMap(report.integration(named:)) }
        rows = filter.apply(to: inventory, predictions: predictions)
            .map { branch in
                BranchRow(branch, integrationNames: names, mergePrediction: firstIntegration?.prediction(for: branch.name),
                          predictionsLoaded: predictions != nil, pullRequest: pullRequests[branch.name])
            }
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

/// Reference box so the sessions model reads the repository's current config, not a copy from start-up.
@MainActor
final class ConfigHolder {
    var value = RepoConfig.defaults
}
