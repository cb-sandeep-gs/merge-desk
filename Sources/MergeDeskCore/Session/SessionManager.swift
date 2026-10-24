import Foundation

public enum SessionError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalidTransition(from: SessionState, to: SessionState)
    case unknownBranch(String)
    case sameBranch
    case nothingToMerge(source: String, target: String)
    case branchCheckedOut(branch: String, worktree: String)
    case branchMoved(branch: String, expected: String, actual: String?)
    case branchExists(String)
    case unresolved([String])
    case protectedBranch(String)
    case notConfirmed
    case notGitHub(String)
    case gitFailed(String)

    public var description: String {
        switch self {
        case let .invalidTransition(from, to): return "Can't go from \(from.title) to \(to.title)."
        case let .unknownBranch(name): return "No branch named '\(name)'."
        case .sameBranch: return "Source and target are the same branch."
        case let .nothingToMerge(source, target): return "'\(source)' is already fully merged into '\(target)'."
        case let .branchCheckedOut(branch, worktree):
            return "'\(branch)' is checked out in \(worktree). Merge Desk never moves a checked-out branch — "
                + "switch that checkout to another branch, or run `git merge --ff-only` there yourself."
        case let .branchMoved(branch, expected, actual):
            return "'\(branch)' moved since this session started (expected \(expected.prefix(10)), "
                + "found \(actual.map { String($0.prefix(10)) } ?? "nothing")). Abort and start a new merge."
        case let .branchExists(name): return "A branch named '\(name)' already exists."
        case let .unresolved(files): return "Still unresolved: \(files.joined(separator: ", "))"
        case let .protectedBranch(name): return "'\(name)' is protected: it only changes through a pull request."
        case .notConfirmed: return "Pushing needs an explicit confirmation."
        case let .notGitHub(remote): return "The remote '\(remote)' isn't on GitHub; push the branch and open the pull request yourself."
        case let .gitFailed(message): return message
        }
    }

    public var errorDescription: String? { description }
}

/// Runs merge sessions for one repository (PLAN.md §6.3). Every step re-reads the saved session, checks the
/// transition, does its git work, then saves and audits. Safety rules:
/// - the merge itself happens in a separate worktree under Merge Desk's support folder, never in a checkout;
/// - a branch is only moved by compare-and-swap from the commit recorded at preflight, and never while checked out;
/// - before moving a branch its old commit is kept under `refs/mergedesk/backup/…`;
/// - pushing needs `confirmed: true`, never forces, and protected targets only ever get a pull request.
public struct SessionManager: Sendable {
    static let worktreesFolderName = "worktrees"
    /// Git's way of saying "this ref must not exist yet" in a compare-and-swap.
    static func zeroID(like id: String) -> String { String(repeating: "0", count: id.count) }
    static let conflictMarkerPrefixes = ["<<<<<<< ", ">>>>>>> ", "||||||| "]

    public let repositoryRoot: URL
    public let store: SessionStore
    // Internal (not private): the steps live in SessionManager+Steps.swift.
    let config: RepoConfig
    let git: GitClient
    let paths: SupportPaths
    let github: GitHubCLI
    let audit: AuditLog
    let now: @Sendable () -> Date

    public init(repositoryRoot: URL, config: RepoConfig, git: GitClient = ProcessGitClient(),
                paths: SupportPaths = SupportPaths(), github: GitHubCLI = GitHubCLI(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.repositoryRoot = repositoryRoot
        self.config = config
        self.git = git
        self.paths = paths
        self.github = github
        self.store = SessionStore(paths: paths, repositoryRoot: repositoryRoot)
        self.audit = AuditLog(fileURL: paths.auditLog(for: repositoryRoot))
        self.now = now
    }

    // MARK: - Plan

    public func plan(source: String, target: String, strategy: MergeStrategy = .mergeCommit) async throws -> MergeSession {
        guard source != target else { throw SessionError.sameBranch }
        let groups = try await branchGroups()
        guard let sourceGroup = groups[source] else { throw SessionError.unknownBranch(source) }
        guard let targetGroup = groups[target] else { throw SessionError.unknownBranch(target) }
        if try await git.execute(.isAncestor(sourceGroup.tip.objectID, of: targetGroup.tip.objectID), in: repositoryRoot) {
            throw SessionError.nothingToMerge(source: source, target: target)
        }
        let session = MergeSession(repositoryPath: repositoryRoot.path, source: source, target: target, strategy: strategy,
                                   viaPullRequest: config.isProtected(branch: target), now: now())
        try store.save(session)
        try await record(.sessionPlanned, session)
        return session
    }

    // MARK: - Start: preflight → merging → resolving | ready

    public func start(_ sessionID: UUID, fetch: Bool = true) async throws -> MergeSession {
        var session = try store.load(sessionID)
        try transition(&session, to: .preflight)
        do {
            if fetch { try await fetchPrimaryRemote(&session) }
            try await recordCommits(&session)
            try transition(&session, to: .merging)
            try await createWorktree(&session)
            let conflicts = try await runMerge(&session)
            if conflicts.isEmpty {
                try transition(&session, to: .verifying)
                try await commit(&session)
            } else {
                session.conflictedFiles = conflicts
                let note = conflicts.count == 1 ? "1 conflicted file" : "\(conflicts.count) conflicted files"
                try transition(&session, to: .resolving, note: note)
            }
            return session
        } catch {
            // Nothing outside Merge Desk changed yet: clean up and finish the session as aborted.
            session.lastError = error.localizedDescription
            try? store.save(session)
            if session.state != .resolving { _ = try? await abort(session.id) }
            throw error
        }
    }

    /// After the conflicts were edited in the worktree: refuses while markers remain, else stages and commits.
    public func continueAfterResolving(_ sessionID: UUID) async throws -> MergeSession {
        var session = try store.load(sessionID)
        guard session.state == .resolving, let worktree = session.worktreePath.map(URL.init(fileURLWithPath:)) else {
            throw SessionError.invalidTransition(from: session.state, to: .verifying)
        }
        let withMarkers = session.conflictedFiles.filter { Self.hasConflictMarkers(worktree.appendingPathComponent($0)) }
        guard withMarkers.isEmpty else {
            session.lastError = SessionError.unresolved(withMarkers).description
            try store.save(session)
            throw SessionError.unresolved(withMarkers)
        }
        // `add --all -- <paths>` also records files resolved by deleting them.
        try await checked(["add", "--all", "--"] + session.conflictedFiles, in: worktree)
        let remaining = try await git.execute(.unmergedPaths, in: worktree)
        guard remaining.isEmpty else { throw SessionError.unresolved(remaining) }
        try transition(&session, to: .verifying)
        try await commit(&session)
        return session
    }

    // MARK: - Apply / undo

    /// Points a local branch at the merge: the target itself, or a new `mergedesk/…` branch for protected targets.
    public func apply(_ sessionID: UUID) async throws -> MergeSession {
        var session = try store.load(sessionID)
        guard session.state == .ready, let result = session.resultID else {
            throw SessionError.invalidTransition(from: session.state, to: .applied)
        }
        let branch = session.pullRequestBranch ?? session.target
        try await ensureNotCheckedOut(branch, except: session.worktreePath)
        let current = try await localBranchID(branch)

        let change: AppliedChange
        if session.viaPullRequest || session.targetLocalID == nil {
            // No local copy to move (or a protected target): create the branch, and only if it still doesn't exist.
            if let current {
                throw session.viaPullRequest ? SessionError.branchExists(branch)
                    : SessionError.branchMoved(branch: branch, expected: Self.zeroID(like: result), actual: current)
            }
            try await updateRef(branch, to: result, expected: Self.zeroID(like: result), session: session)
            if !session.viaPullRequest { await trackPrimaryRemote(branch) }
            change = .createdBranch(branch: branch)
        } else {
            guard let expected = session.targetLocalID, current == expected else {
                throw SessionError.branchMoved(branch: branch, expected: session.targetLocalID ?? "", actual: current)
            }
            let backup = SessionNaming.backupRef(branch: branch, at: now())
            try await checked(["update-ref", "-m", "mergedesk: backup before \(session.shortID)", backup, expected,
                               Self.zeroID(like: expected)], in: repositoryRoot)
            do {
                try await updateRef(branch, to: result, expected: expected, session: session)
            } catch {
                _ = try? await git.run(["update-ref", "-d", backup, expected], in: repositoryRoot)
                throw SessionError.branchMoved(branch: branch, expected: expected, actual: try await localBranchID(branch))
            }
            change = .movedBranch(branch: branch, previousID: expected, backupRef: backup)
        }
        session.applied = change
        try transition(&session, to: .applied, note: branch)
        await removeWorktree(&session)
        try await record(.mergeApplied, session, branch: branch, before: change.previousID, after: result,
                         backupRef: change.backupRef)
        return session
    }

    /// Puts the branch back exactly where it was before Apply. Refused after a push, or if the branch moved since.
    public func undo(_ sessionID: UUID) async throws -> MergeSession {
        var session = try store.load(sessionID)
        guard session.state == .applied, let change = session.applied, let result = session.resultID else {
            throw SessionError.invalidTransition(from: session.state, to: .undone)
        }
        try await ensureNotCheckedOut(change.branch, except: nil)
        let current = try await localBranchID(change.branch)
        guard current == result else { throw SessionError.branchMoved(branch: change.branch, expected: result, actual: current) }
        switch change {
        case let .movedBranch(branch, previousID, _):
            try await updateRef(branch, to: previousID, expected: result, session: session, verb: "undo")
        case let .createdBranch(branch):
            try await checked(["update-ref", "-m", "mergedesk: undo \(session.shortID)", "-d", "refs/heads/\(branch)", result],
                              in: repositoryRoot)
        }
        try transition(&session, to: .undone, note: change.branch)
        await deleteSessionRef(session)
        try await record(.mergeUndone, session, branch: change.branch, before: result, after: change.previousID)
        return session
    }

    // MARK: - Push / pull request

    /// Pushes the target branch (fast-forward only). Protected targets are refused: use `openPullRequest`.
    public func push(_ sessionID: UUID, confirmed: Bool) async throws -> MergeSession {
        guard confirmed else { throw SessionError.notConfirmed }
        var session = try store.load(sessionID)
        guard !session.viaPullRequest, !config.isProtected(branch: session.target) else {
            throw SessionError.protectedBranch(session.target)
        }
        guard session.state == .applied, let branch = session.applied?.branch else {
            throw SessionError.invalidTransition(from: session.state, to: .pushed)
        }
        try await pushBranch(branch)
        try transition(&session, to: .pushed, note: "\(config.primaryRemote)/\(branch)")
        await deleteSessionRef(session)
        try await record(.branchPushed, session, branch: branch, after: session.resultID)
        return session
    }

    /// Pushes the `mergedesk/…` branch and opens a pull request into the protected target — with `gh` when it is
    /// installed and signed in, otherwise by returning GitHub's compare page.
    public func openPullRequest(_ sessionID: UUID, confirmed: Bool) async throws -> MergeSession {
        guard confirmed else { throw SessionError.notConfirmed }
        var session = try store.load(sessionID)
        guard session.state == .applied, session.viaPullRequest, let branch = session.pullRequestBranch else {
            throw SessionError.invalidTransition(from: session.state, to: .pullRequestOpened)
        }
        // Decide the route before pushing, so a remote that isn't on GitHub fails without leaving a pushed branch.
        let useCLI = await github.isAvailable(in: repositoryRoot)
        var compareURL: URL?
        if !useCLI {
            let remoteURL = try await git.execute(.remoteURL(config.primaryRemote), in: repositoryRoot)
            compareURL = GitHubRepository(remoteURL: remoteURL)?.compareURL(base: session.target, head: branch)
            guard compareURL != nil else { throw SessionError.notGitHub(config.primaryRemote) }
        }
        try await pushBranch(branch)
        let url: URL
        if let compareURL {
            url = compareURL
        } else {
            url = try await github.createPullRequest(base: session.target, head: branch, title: session.title,
                                                     body: Self.pullRequestBody(session), in: repositoryRoot)
        }
        session.pullRequestURL = url.absoluteString
        try transition(&session, to: .pullRequestOpened, note: url.absoluteString)
        await deleteSessionRef(session)
        try await record(.pullRequestOpened, session, branch: branch, after: session.resultID, details: ["url": url.absoluteString])
        return session
    }

    // MARK: - Abort

    /// Gives up before Apply: removes the worktree and the session ref. Nothing outside Merge Desk had changed.
    @discardableResult
    public func abort(_ sessionID: UUID) async throws -> MergeSession {
        var session = try store.load(sessionID)
        guard SessionStateMachine.canTransition(from: session.state, to: .aborted) else {
            throw SessionError.invalidTransition(from: session.state, to: .aborted)
        }
        await removeWorktree(&session)
        await deleteSessionRef(session)
        try transition(&session, to: .aborted)
        try await record(.mergeAborted, session)
        return session
    }
}

extension AppliedChange {
    var previousID: String? {
        if case let .movedBranch(_, previous, _) = self { return previous }
        return nil
    }

    var backupRef: String? {
        if case let .movedBranch(_, _, backup) = self { return backup }
        return nil
    }
}
