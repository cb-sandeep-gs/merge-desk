import Foundation

/// Resolving conflicts by hand, one file at a time, in a session's worktree.
extension SessionManager {
    /// The conflict in `path`, built from git's three versions (independent of the user's conflict-style setting).
    public func fileConflict(_ sessionID: UUID, path: String) async throws -> FileConflict {
        let (_, worktree) = try resolvingSession(sessionID, path: path)
        let input = try await AutoResolver(git: git, config: config).stages(of: path, in: worktree)
        guard let ours = input.ours, let theirs = input.theirs else {
            return .presentOnOneSide(inInto: input.ours != nil, inFrom: input.theirs != nil)
        }
        if Self.isBinary(ours) || Self.isBinary(theirs) { return .binary }
        return .text(try await ConflictedText.make(base: input.base, ours: ours, theirs: theirs, git: git))
    }

    /// Takes one whole side of `path` (deleting the file if that side doesn't have it).
    public func useVersion(_ sessionID: UUID, path: String, side: ConflictSide) async throws -> MergeSession {
        let (_, worktree) = try resolvingSession(sessionID, path: path)
        let input = try await AutoResolver(git: git, config: config).stages(of: path, in: worktree)
        let branch = try store.load(sessionID)
        let name = side == .into ? branch.target : branch.source
        return try await resolveFile(sessionID, path: path, content: side == .into ? input.ours : input.theirs,
                                     note: "kept \(name)'s version")
    }

    /// Writes a person's resolution of `path` (nil = delete the file), stages it, and records it.
    public func resolveFile(_ sessionID: UUID, path: String, content: Data?, note: String = "resolved by you") async throws
        -> MergeSession {
        var (session, worktree) = try resolvingSession(sessionID, path: path)
        let file = worktree.appendingPathComponent(path)
        if let content {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        guard !Self.hasConflictMarkers(file) else { throw SessionError.unresolved([path]) }
        try await git.run(["add", "--all", "--", path], in: worktree).requireSuccess()

        session.conflictedFiles.removeAll { $0 == path }
        var resolutions = (session.resolutions ?? []).filter { $0.path != path }
        resolutions.append(FileResolution(path: path, tier: .manual, status: .applied, confidence: nil, note: note))
        session.resolutions = resolutions.sorted { $0.path < $1.path }
        session.lastError = nil
        session.updatedAt = now()
        try store.save(session)
        try await record(.fileResolved, session, details: ["path": path, "how": note])
        return session
    }

    /// The session (in resolving, with `path` still conflicted) and its worktree.
    private func resolvingSession(_ sessionID: UUID, path: String) throws -> (MergeSession, URL) {
        let session = try store.load(sessionID)
        guard session.state == .resolving, let worktree = session.worktreePath.map(URL.init(fileURLWithPath:)) else {
            throw SessionError.invalidTransition(from: session.state, to: .verifying)
        }
        guard session.conflictedFiles.contains(path) else { throw SessionError.unresolved([]) }
        return (session, worktree)
    }

    /// git's own heuristic: a NUL byte in the first 8000 bytes means binary.
    static func isBinary(_ data: Data) -> Bool {
        data.prefix(binarySniffLength).contains(0)
    }

    static let binarySniffLength = 8_000
}
