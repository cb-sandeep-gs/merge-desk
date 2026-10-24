import Foundation

/// How the source branch is brought into the target.
public enum MergeStrategy: String, Sendable, Codable, CaseIterable {
    /// A merge commit with two parents (history of both branches kept).
    case mergeCommit = "merge"
    /// One new commit on the target with the source's combined changes.
    case squash

    public var title: String {
        switch self {
        case .mergeCommit: return "Merge commit"
        case .squash: return "Squash"
        }
    }
}

/// Where a merge session is (PLAN.md §6.3). Transitions are checked by `SessionStateMachine`.
public enum SessionState: String, Sendable, Codable, CaseIterable {
    case planned
    /// Fetching and recording commit ids (transient).
    case preflight
    /// Running `git merge` in the session's worktree (transient).
    case merging
    /// Conflicts to resolve in the worktree.
    case resolving
    /// Checking the resolution and committing (transient).
    case verifying
    /// Merge commit made in the worktree; nothing outside Merge Desk changed yet.
    case ready
    /// A local branch now points at the merge (the target, or a new `mergedesk/…` branch for protected targets).
    case applied
    /// The target branch was pushed.
    case pushed
    /// The merge branch was pushed and a pull request opened (or its compare page shown).
    case pullRequestOpened
    /// Given up before applying; the worktree is gone.
    case aborted
    /// Applied, then undone: the branch is back where it was.
    case undone

    /// No further action possible.
    public var isFinished: Bool { [.pushed, .pullRequestOpened, .aborted, .undone].contains(self) }
    /// States only seen while an operation is running; finding one on disk means the app quit mid-operation.
    public var isTransient: Bool { [.preflight, .merging, .verifying].contains(self) }

    public var title: String {
        switch self {
        case .planned: return "Planned"
        case .preflight: return "Preparing"
        case .merging: return "Merging"
        case .resolving: return "Needs resolving"
        case .verifying: return "Verifying"
        case .ready: return "Ready to apply"
        case .applied: return "Applied locally"
        case .pushed: return "Pushed"
        case .pullRequestOpened: return "Pull request"
        case .aborted: return "Aborted"
        case .undone: return "Undone"
        }
    }
}

/// The allowed transitions — the one place that says what may follow what.
public enum SessionStateMachine {
    static let transitions: [SessionState: Set<SessionState>] = [
        .planned: [.preflight, .aborted],
        .preflight: [.merging, .aborted],
        .merging: [.resolving, .verifying, .aborted],
        .resolving: [.verifying, .aborted],
        .verifying: [.ready, .resolving, .aborted],
        .ready: [.applied, .aborted],
        .applied: [.pushed, .pullRequestOpened, .undone],
        .pushed: [],
        .pullRequestOpened: [],
        .aborted: [],
        .undone: [],
    ]

    public static func canTransition(from: SessionState, to: SessionState) -> Bool {
        transitions[from]?.contains(to) ?? false
    }
}

/// One step in a session's history.
public struct SessionEvent: Sendable, Equatable, Codable {
    public let state: SessionState
    public let at: Date
    public let note: String?
}

/// What "Apply" did, so "Undo" can reverse exactly that.
public enum AppliedChange: Sendable, Equatable, Codable {
    /// An existing local branch moved from `previousID` to the merge; `backupRef` keeps the old commit.
    case movedBranch(branch: String, previousID: String, backupRef: String)
    /// A new local branch was created at the merge (target had no local copy, or the target is protected).
    case createdBranch(branch: String)

    public var branch: String {
        switch self {
        case let .movedBranch(branch, _, _), let .createdBranch(branch): return branch
        }
    }
}

/// A merge of `source` into `target`, from plan to push. Persisted after every step.
public struct MergeSession: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let repositoryPath: String
    public let createdAt: Date
    public var updatedAt: Date

    public let source: String
    public let target: String
    public let strategy: MergeStrategy
    /// The target is protected: the merge goes to a new branch and a pull request, never straight to `target`.
    public let viaPullRequest: Bool

    /// Commit ids fixed at preflight: the merge is exactly these two commits.
    public var sourceID: String?
    public var baseID: String?
    /// Ref the base came from (whichever of the local and remote copies contains the other).
    public var baseRef: String?
    /// Where the local target branch was at preflight; Apply moves it only from here (nil = no local copy, so
    /// Apply creates it).
    public var targetLocalID: String?

    public var state: SessionState
    public var worktreePath: String?
    /// Files still conflicted, for a person (after the automatic tiers).
    public var conflictedFiles: [String]
    /// What the automatic tiers did with each conflicted file. Optional so sessions saved before MD-4 still load.
    public var resolutions: [FileResolution]?
    /// The merge (or squash) commit made in the worktree.
    public var resultID: String?
    public var applied: AppliedChange?
    public var pullRequestURL: String?
    public var warnings: [String]
    /// Last failure, shown next to the state; cleared by the next successful step.
    public var lastError: String?
    public var history: [SessionEvent]

    init(id: UUID = UUID(), repositoryPath: String, source: String, target: String, strategy: MergeStrategy,
         viaPullRequest: Bool, now: Date) {
        self.id = id
        self.repositoryPath = repositoryPath
        self.createdAt = now
        self.updatedAt = now
        self.source = source
        self.target = target
        self.strategy = strategy
        self.viaPullRequest = viaPullRequest
        self.state = .planned
        self.conflictedFiles = []
        self.warnings = []
        self.history = [SessionEvent(state: .planned, at: now, note: nil)]
    }

    /// Branch the pull request comes from, for protected targets.
    public var pullRequestBranch: String? {
        guard viaPullRequest else { return nil }
        return SessionNaming.pullRequestBranch(source: source, target: target, id: id)
    }

    /// The one-line title used for the merge commit and the pull request.
    public var title: String {
        switch strategy {
        case .mergeCommit: return "Merge branch '\(source)' into \(target)"
        case .squash: return "Squash merge branch '\(source)' into \(target)"
        }
    }

    /// Short id for display and CLI arguments (first block of the UUID).
    public var shortID: String { String(id.uuidString.prefix(SessionNaming.shortIDLength)).lowercased() }
}

/// Names Merge Desk creates in a repository.
public enum SessionNaming {
    /// Prefix of branches created for pull requests into protected targets.
    public static let pullRequestBranchPrefix = "mergedesk/"
    /// Keeps the session's result commit reachable (so git gc can't drop it) until the session ends.
    public static let sessionRefNamespace = "refs/mergedesk/sessions"
    static let shortIDLength = 8

    public static func pullRequestBranch(source: String, target: String, id: UUID) -> String {
        let safe = { (name: String) in
            String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" })
        }
        return "\(pullRequestBranchPrefix)\(safe(source))-into-\(safe(target))-\(id.uuidString.prefix(shortIDLength).lowercased())"
    }

    public static func sessionRef(_ id: UUID) -> String { "\(sessionRefNamespace)/\(id.uuidString.lowercased())" }

    /// `refs/mergedesk/backup/<UTC yyyyMMdd-HHmmss>/<branch>`.
    public static func backupRef(branch: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(MergeDeskConstants.backupRefNamespace)/\(formatter.string(from: date))/\(branch)"
    }
}
