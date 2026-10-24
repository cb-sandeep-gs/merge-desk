import Foundation
import MergeDeskCore
import Observation

/// What the Merge tab shows before anything runs.
public struct MergePreview: Sendable, Equatable {
    /// Commits on "from" that "into" doesn't have yet.
    public let commitsToBring: Int
    /// Predicted result (nil when there's nothing to merge).
    public let prediction: MergePrediction?
    public let intoIsProtected: Bool

    public var nothingToMerge: Bool { commitsToBring == 0 }
}

/// Where the guided merge is, in plain terms.
public enum MergeStep: Equatable, Sendable {
    /// Pick the two branches.
    case choose
    /// Git is working.
    case working
    /// Some files need a person.
    case resolveConflicts
    /// Every conflict resolved; the merge can be completed.
    case readyToComplete
    /// Merge made (in its own worktree); nothing in the branches changed yet.
    case readyToApply
    /// The branch now contains the merge, locally.
    case applied
    /// Pushed, or a pull request opened.
    case done
}

/// The Merge tab: choose "merge into" and "merge from", see what will happen, press Merge, resolve what's left,
/// then apply. Wraps a merge session; the session manager enforces every safety rule.
@MainActor
@Observable
public final class MergeFlowModel {
    /// The branch that receives the changes (the "input branch").
    public var into: String? {
        didSet { if into != oldValue { refreshPreview() } }
    }
    /// The branch whose changes are brought in.
    public var from: String? {
        didSet { if from != oldValue { refreshPreview() } }
    }
    public var strategy: MergeStrategy = .mergeCommit
    public var fetchFirst = true

    public private(set) var preview: LoadState<MergePreview> = .idle
    /// The session this tab is driving.
    public private(set) var sessionID: UUID?

    /// The file open in the Resolve sheet.
    public var resolvingPath: String?
    public private(set) var fileConflict: LoadState<FileConflict> = .idle
    /// One choice per conflict block of the open file (nil = not decided yet).
    public var choices: [BlockChoice?] = []

    private let sessions: SessionsModel
    private let git: GitClient
    @ObservationIgnored private let inventoryProvider: @MainActor () -> RepositoryInventory?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    init(sessions: SessionsModel, git: GitClient, inventory: @escaping @MainActor () -> RepositoryInventory?) {
        self.sessions = sessions
        self.git = git
        self.inventoryProvider = inventory
        resumeOpenSession()
    }

    // MARK: - State

    public var session: MergeSession? { sessions.sessions.first { $0.id == sessionID } }
    public var isBusy: Bool { sessions.isBusy }
    public var errorMessage: String? { sessions.errorMessage }

    public var step: MergeStep {
        guard let session else { return .choose }
        switch session.state {
        case .planned, .preflight, .merging, .verifying: return .working
        case .resolving: return session.conflictedFiles.isEmpty ? .readyToComplete : .resolveConflicts
        case .ready: return .readyToApply
        case .applied: return .applied
        case .pushed, .pullRequestOpened: return .done
        case .aborted, .undone: return .choose
        }
    }

    /// Branches for the pickers: integration branches first, then everything else by name.
    public var branchChoices: [String] {
        guard let inventory = inventoryProvider() else { return [] }
        let integration = inventory.integrationRefs.map(\.name)
        return integration + inventory.branches.map(\.name).filter { !integration.contains($0) }
    }

    public var integrationBranches: Set<String> { Set(inventoryProvider()?.integrationRefs.map(\.name) ?? []) }

    /// Why Merge is disabled, in words; nil when it can run.
    public var mergeBlockedReason: String? {
        guard let into, let from else { return "Choose both branches." }
        if into == from { return "Choose two different branches." }
        switch preview {
        case .loading, .idle: return "Checking…"
        case let .failed(message): return message
        case let .loaded(preview): return preview.nothingToMerge ? "\(into) already has everything from \(from)." : nil
        }
    }

    // MARK: - Actions

    public func swapBranches() {
        (into, from) = (from, into)
    }

    public func merge() async {
        guard mergeBlockedReason == nil, let into, let from else { return }
        await sessions.startMerge(source: from, target: into, strategy: strategy, fetch: fetchFirst)
        sessionID = sessions.selectedSessionID
    }

    /// Commits the merge once every file is resolved.
    public func complete() async { await run(.continueResolving) }
    public func apply() async { await run(.apply) }
    public func undo() async { await run(.undo) }
    /// Push (normal targets) or push + pull request (protected targets). Only after the user confirmed.
    public func publish() async {
        guard let session else { return }
        await run(session.viaPullRequest ? .openPullRequest : .push, confirmed: true)
    }

    /// Throws the merge away (before Apply) and goes back to choosing.
    public func discard() async {
        await run(.abort)
        sessionID = nil
    }

    /// After a finished merge: start over with the same branches.
    public func startOver() {
        sessionID = nil
        refreshPreview()
    }

    // MARK: - Resolving one file

    public func openResolver(_ path: String) async {
        guard let session else { return }
        resolvingPath = path
        fileConflict = .loading
        choices = []
        do {
            let conflict = try await sessions.fileConflict(session, path: path)
            if case let .text(text) = conflict { choices = Array(repeating: nil, count: text.conflictCount) }
            fileConflict = .loaded(conflict)
        } catch {
            fileConflict = .failed(ErrorText.message(error))
        }
    }

    /// Every block decided: the result can be saved.
    public var canSaveChoices: Bool { !choices.isEmpty && choices.allSatisfy { $0 != nil } }

    /// The file as it will be saved with the current choices (nil until every block is decided).
    public var resolvedPreview: String? {
        guard case let .loaded(.text(text)) = fileConflict, canSaveChoices else { return nil }
        return text.render(choices: choices.compactMap { $0 })
    }

    public func chooseForAll(_ choice: BlockChoice) {
        choices = choices.map { _ in choice }
    }

    public func saveChoices() async {
        guard let session, let path = resolvingPath, let text = resolvedPreview else { return }
        await sessions.resolve(session, path: path, content: Data(text.utf8))
        closeResolver()
    }

    /// Keep one side's whole file (also how a file deleted on one side is decided).
    public func keepWholeFile(_ side: ConflictSide) async {
        guard let session, let path = resolvingPath else { return }
        await sessions.useVersion(session, path: path, side: side)
        closeResolver()
    }

    /// After editing the file in an editor: saves it as the resolution (refused while conflict markers remain).
    public func markEditedResolved() async {
        guard let session, let path = resolvingPath, let worktree = session.worktreePath else { return }
        let content = try? Data(contentsOf: URL(fileURLWithPath: worktree).appendingPathComponent(path))
        await sessions.resolve(session, path: path, content: content)
        if sessions.errorMessage == nil { closeResolver() }
    }

    public func closeResolver() {
        resolvingPath = nil
        fileConflict = .idle
        choices = []
    }

    // MARK: - Private

    private func run(_ action: SessionAction, confirmed: Bool = false) async {
        guard let session else { return }
        await sessions.run(action, on: session, confirmed: confirmed)
    }

    /// Picks up a merge left open (app quit mid-way) so the tab continues where it was.
    private func resumeOpenSession() {
        guard let open = sessions.sessions.first(where: { !$0.state.isFinished && $0.state != .applied }) else { return }
        sessionID = open.id
        into = open.target
        from = open.source
    }

    /// Commits to bring in and the predicted conflicts, for the chosen pair.
    private func refreshPreview() {
        previewTask?.cancel()
        guard let into, let from, into != from, let inventory = inventoryProvider(),
              let intoTip = inventory.branch(named: into)?.tip.objectID,
              let fromTip = inventory.branch(named: from)?.tip.objectID else {
            preview = .idle
            return
        }
        preview = .loading
        let git = self.git
        let root = URL(fileURLWithPath: inventory.repositoryPath)
        let sessions = self.sessions
        let isProtected = sessions.isProtected(into)
        previewTask = Task { [weak self] in
            do {
                let counts = try await git.execute(.aheadBehind(branch: fromTip, base: intoTip), in: root)
                let prediction = counts.ahead == 0 ? nil : await sessions.preview(source: from, target: into, inventory: inventory)
                guard !Task.isCancelled else { return }
                self?.preview = .loaded(MergePreview(commitsToBring: counts.ahead, prediction: prediction, intoIsProtected: isProtected))
            } catch {
                guard !Task.isCancelled else { return }
                self?.preview = .failed(ErrorText.message(error))
            }
        }
    }

    /// Waits for the preview (tests).
    public func waitForPreview() async { await previewTask?.value }
}
