import Foundation

/// The individual git steps behind `SessionManager`'s public operations.
extension SessionManager {
    // MARK: - Steps

    func fetchPrimaryRemote(_ session: inout MergeSession) async throws {
        let result = try await git.run(["fetch", "--prune", "--quiet", config.primaryRemote], in: repositoryRoot)
        if result.exitCode != GitExitCode.success {
            session.warnings.append("Fetch failed (\(result.errorText)); merged the last fetched state.")
        }
    }

    /// Fixes the two commits the merge is made of. For each side, when the local and remote copies differ, the one
    /// that contains the other is used (local wins only if it is ahead or diverged — then with a warning).
    func recordCommits(_ session: inout MergeSession) async throws {
        let groups = try await branchGroups()
        guard let source = groups[session.source] else { throw SessionError.unknownBranch(session.source) }
        guard let target = groups[session.target] else { throw SessionError.unknownBranch(session.target) }
        let sourceRef = try await newestCopy(source, warnings: &session.warnings)
        let baseRef = try await newestCopy(target, warnings: &session.warnings)
        if try await git.execute(.isAncestor(sourceRef.objectID, of: baseRef.objectID), in: repositoryRoot) {
            throw SessionError.nothingToMerge(source: session.source, target: session.target)
        }
        session.sourceID = sourceRef.objectID
        session.baseID = baseRef.objectID
        session.baseRef = baseRef.fullName
        session.targetLocalID = target.local?.objectID
        if let local = target.local, local.objectID != baseRef.objectID, !session.viaPullRequest {
            // Base is the remote copy and local is behind it: the merge contains local, so Apply loses nothing.
            session.warnings.append(
                "Local '\(session.target)' is behind \(baseRef.shortName); the merge includes the newer remote commits.")
        }
        try store.save(session)
    }

    func newestCopy(_ group: InventoryBuilder.BranchGroup, warnings: inout [String]) async throws -> GitRef {
        guard let local = group.local, let remote = group.primary, local.objectID != remote.objectID else {
            return group.local ?? group.tip
        }
        if try await git.execute(.isAncestor(remote.objectID, of: local.objectID), in: repositoryRoot) { return local }
        if try await git.execute(.isAncestor(local.objectID, of: remote.objectID), in: repositoryRoot) { return remote }
        warnings.append("Local '\(group.name)' and \(remote.shortName) have diverged; merging the local copy. "
                        + "Pull it first to include the remote work.")
        return local
    }

    func createWorktree(_ session: inout MergeSession) async throws {
        guard let base = session.baseID else { throw SessionError.invalidTransition(from: session.state, to: .merging) }
        let folder = paths.repositoryFolder(for: repositoryRoot)
            .appendingPathComponent(Self.worktreesFolderName, isDirectory: true)
            .appendingPathComponent(session.shortID, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await checked(["worktree", "add", "--detach", "--quiet", folder.path, base], in: repositoryRoot)
        session.worktreePath = folder.path
        try store.save(session)
    }

    /// Runs the merge in the worktree; returns the conflicted paths (empty = clean).
    func runMerge(_ session: inout MergeSession) async throws -> [String] {
        guard let worktree = session.worktreePath.map(URL.init(fileURLWithPath:)), let source = session.sourceID else { return [] }
        let arguments = session.strategy == .squash
            ? ["merge", "--squash", "--quiet", source]
            : ["merge", "--no-ff", "--no-commit", "--quiet", source]
        let result = try await git.run(arguments, in: worktree)
        let unmerged = try await git.execute(.unmergedPaths, in: worktree)
        guard result.exitCode == GitExitCode.success || !unmerged.isEmpty else {
            throw SessionError.gitFailed(result.errorText)
        }
        return unmerged
    }

    /// Commits in the worktree. The repository's own commit hooks run; a failing hook sends the session back to
    /// resolving with the hook's message.
    func commit(_ session: inout MergeSession) async throws {
        guard let worktree = session.worktreePath.map(URL.init(fileURLWithPath:)) else { return }
        let result = try await git.run(["commit", "--quiet", "--message", session.title], in: worktree)
        guard result.exitCode == GitExitCode.success else {
            session.lastError = "Commit failed: \(result.errorText)"
            try transition(&session, to: .resolving, note: "commit failed")
            throw SessionError.gitFailed(session.lastError ?? result.errorText)
        }
        let head = try await git.execute(.commitID(of: "HEAD"), in: worktree)
        session.resultID = head
        // Keeps the commit reachable (git gc) while the session is open.
        try await checked(["update-ref", SessionNaming.sessionRef(session.id), head], in: repositoryRoot)
        session.lastError = nil
        try transition(&session, to: .ready)
    }

    func pushBranch(_ branch: String) async throws {
        let refspec = "refs/heads/\(branch):refs/heads/\(branch)"
        // Never --force: a remote that moved rejects the push and the user decides what to do.
        let result = try await git.run(["push", "--porcelain", "--set-upstream", config.primaryRemote, refspec], in: repositoryRoot)
        guard result.exitCode == GitExitCode.success else { throw SessionError.gitFailed("Push failed: \(result.errorText)") }
    }

    // MARK: - Helpers

    func branchGroups() async throws -> [String: InventoryBuilder.BranchGroup] {
        InventoryBuilder.group(try await git.execute(.branches(), in: repositoryRoot), primaryRemote: config.primaryRemote)
    }

    func localBranchID(_ branch: String) async throws -> String? {
        let result = try await git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: repositoryRoot)
        return result.exitCode == GitExitCode.success ? GitOutputParser.trimmedLine(result.standardOutput) : nil
    }

    func ensureNotCheckedOut(_ branch: String, except worktreePath: String?) async throws {
        let ref = "refs/heads/\(branch)"
        let worktrees = try await git.execute(.worktrees, in: repositoryRoot)
        if let holder = worktrees.first(where: { $0.branchRef == ref && $0.path != worktreePath }) {
            throw SessionError.branchCheckedOut(branch: branch, worktree: holder.path)
        }
    }

    func updateRef(_ branch: String, to new: String, expected: String, session: MergeSession, verb: String = "apply") async throws {
        try await checked(["update-ref", "-m", "mergedesk: \(verb) \(session.shortID) \(session.title)",
                           "refs/heads/\(branch)", new, expected], in: repositoryRoot)
    }

    func trackPrimaryRemote(_ branch: String) async {
        _ = try? await git.run(["branch", "--quiet", "--set-upstream-to=\(config.primaryRemote)/\(branch)", branch], in: repositoryRoot)
    }

    func removeWorktree(_ session: inout MergeSession) async {
        guard let path = session.worktreePath else { return }
        let worktree = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            _ = try? await git.run(["merge", "--abort"], in: worktree)
            _ = try? await git.run(["worktree", "remove", "--force", path], in: repositoryRoot)
        }
        _ = try? await git.run(["worktree", "prune"], in: repositoryRoot)
        session.worktreePath = nil
        try? store.save(session)
    }

    func deleteSessionRef(_ session: MergeSession) async {
        _ = try? await git.run(["update-ref", "-d", SessionNaming.sessionRef(session.id)], in: repositoryRoot)
    }

    func checked(_ arguments: [String], in directory: URL) async throws {
        let result = try await git.run(arguments, in: directory)
        guard result.exitCode == GitExitCode.success else { throw SessionError.gitFailed(result.errorText) }
    }

    func transition(_ session: inout MergeSession, to next: SessionState, note: String? = nil) throws {
        guard SessionStateMachine.canTransition(from: session.state, to: next) else {
            throw SessionError.invalidTransition(from: session.state, to: next)
        }
        let date = now()
        session.state = next
        session.updatedAt = date
        session.history.append(SessionEvent(state: next, at: date, note: note))
        try store.save(session)
    }

    func record(_ action: AuditAction, _ session: MergeSession, branch: String? = nil, before: String? = nil,
                after: String? = nil, backupRef: String? = nil, details: [String: String] = [:]) async throws {
        let base = ["session": session.id.uuidString, "source": session.source, "target": session.target,
                    "strategy": session.strategy.rawValue]
        try await audit.append(AuditEvent(action: action, branch: branch ?? session.target, objectIDBefore: before,
                                          objectIDAfter: after, backupRef: backupRef,
                                          details: base.merging(details) { _, new in new }))
    }

    static func hasConflictMarkers(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).contains { line in
            conflictMarkerPrefixes.contains { line.hasPrefix($0) }
        }
    }

    static func pullRequestBody(_ session: MergeSession) -> String {
        var lines = ["Merges `\(session.source)` into `\(session.target)` (\(session.strategy.title.lowercased())).", ""]
        if !session.conflictedFiles.isEmpty {
            lines.append("Conflicts resolved (\(session.conflictedFiles.count)):")
            lines += session.conflictedFiles.map { "- `\($0)`" }
        }
        return lines.joined(separator: "\n")
    }
}
