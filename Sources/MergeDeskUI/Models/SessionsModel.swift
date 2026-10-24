import Foundation
import MergeDeskCore
import Observation

/// One action the user can take on a session, in the order the detail pane offers them.
public enum SessionAction: String, CaseIterable, Sendable {
    case continueResolving
    case apply
    case push
    case openPullRequest
    case undo
    case abort

    public var title: String {
        switch self {
        case .continueResolving: return "Mark Resolved & Continue"
        case .apply: return "Apply"
        case .push: return "Push…"
        case .openPullRequest: return "Open Pull Request…"
        case .undo: return "Undo"
        case .abort: return "Abort"
        }
    }

    /// Push and pull request go to the remote: they always ask first.
    public var needsConfirmation: Bool { self == .push || self == .openPullRequest }

    /// Actions available in a state (the manager re-checks every one).
    public static func available(for session: MergeSession) -> [SessionAction] {
        switch session.state {
        case .resolving: return [.continueResolving, .abort]
        case .ready: return [.apply, .abort]
        case .applied: return [session.viaPullRequest ? .openPullRequest : .push, .undo]
        case .planned, .preflight, .merging, .verifying: return [.abort]
        case .pushed, .pullRequestOpened, .aborted, .undone: return []
        }
    }
}

/// Merge sessions of one repository for the app: list, start, act, preview.
@MainActor
@Observable
public final class SessionsModel {
    public private(set) var sessions: [MergeSession] = []
    public var selectedSessionID: MergeSession.ID?
    public private(set) var isBusy = false
    public var errorMessage: String?

    private let repository: RegisteredRepository
    private let git: GitClient
    private let paths: SupportPaths
    private let github: GitHubCLI
    /// Called after anything that moved a branch, so the inventory refreshes.
    @ObservationIgnored var onBranchesChanged: (() -> Void)?
    @ObservationIgnored private var configProvider: @MainActor () -> RepoConfig

    init(repository: RegisteredRepository, git: GitClient, paths: SupportPaths, github: GitHubCLI,
         config: @escaping @MainActor () -> RepoConfig) {
        self.repository = repository
        self.git = git
        self.paths = paths
        self.github = github
        self.configProvider = config
        reload()
    }

    public var selected: MergeSession? { sessions.first { $0.id == selectedSessionID } }
    /// Sessions that still need something (shown first and counted on the view's tab).
    public var openCount: Int { sessions.filter { !$0.state.isFinished }.count }

    public func reload() {
        sessions = SessionStore(paths: paths, repositoryRoot: repository.url).all()
        // With nothing selected, show the newest merge that still needs something.
        if selectedSessionID == nil { selectedSessionID = sessions.first { !$0.state.isFinished }?.id }
    }

    var manager: SessionManager {
        SessionManager(repositoryRoot: repository.url, config: configProvider(), git: git, paths: paths, github: github)
    }

    /// Plans and runs a merge; selects the new session whatever happened.
    public func startMerge(source: String, target: String, strategy: MergeStrategy, fetch: Bool) async {
        await perform(changesBranches: false) { manager in
            let planned = try await manager.plan(source: source, target: target, strategy: strategy)
            self.selectedSessionID = planned.id
            _ = try await manager.start(planned.id, fetch: fetch)
        }
    }

    public func run(_ action: SessionAction, on session: MergeSession, confirmed: Bool = false) async {
        await perform(changesBranches: action == .apply || action == .undo) { manager in
            switch action {
            case .continueResolving: _ = try await manager.continueAfterResolving(session.id)
            case .apply: _ = try await manager.apply(session.id)
            case .push: _ = try await manager.push(session.id, confirmed: confirmed)
            case .openPullRequest: _ = try await manager.openPullRequest(session.id, confirmed: confirmed)
            case .undo: _ = try await manager.undo(session.id)
            case .abort: _ = try await manager.abort(session.id)
            }
        }
    }

    /// Conflicts a merge of `source` into `target` would have right now (merge-tree, nothing touched).
    public func preview(source: String, target: String, inventory: RepositoryInventory) async -> MergePrediction? {
        guard let sourceTip = inventory.branch(named: source)?.tip.objectID,
              let targetTip = inventory.branch(named: target)?.tip.objectID,
              let result = try? await git.execute(.mergeTree(target: targetTip, source: sourceTip), in: repository.url) else {
            return nil
        }
        return MergePrediction(targetID: targetTip, sourceID: sourceTip, outcome: MergeOutcome(result), config: configProvider())
    }

    public func isProtected(_ branch: String) -> Bool { configProvider().isProtected(branch: branch) }

    // MARK: - Resolving by hand

    /// The conflict in one file of a session, for the Resolve sheet.
    public func fileConflict(_ session: MergeSession, path: String) async throws -> FileConflict {
        try await manager.fileConflict(session.id, path: path)
    }

    /// Saves a resolution written in the Resolve sheet (nil = delete the file).
    public func resolve(_ session: MergeSession, path: String, content: Data?) async {
        await perform(changesBranches: false) { manager in
            _ = try await manager.resolveFile(session.id, path: path, content: content)
        }
    }

    /// Keeps one whole side of a file.
    public func useVersion(_ session: MergeSession, path: String, side: ConflictSide) async {
        await perform(changesBranches: false) { manager in
            _ = try await manager.useVersion(session.id, path: path, side: side)
        }
    }

    private func perform(changesBranches: Bool, _ work: @escaping (SessionManager) async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        do {
            try await work(manager)
        } catch {
            errorMessage = ErrorText.message(error)
        }
        reload()
        isBusy = false
        // Apply/undo move branches; push only updates remote-tracking refs — refresh either way after those.
        if changesBranches || errorMessage == nil { onBranchesChanged?() }
    }
}
