import Foundation

/// How one automatically handled file compares with what a person actually committed (PLAN.md §7).
public enum ReplayVerdict: String, Sendable, Codable, CaseIterable {
    /// Byte-for-byte the committed file.
    case exact
    /// Same content, different layout (JSON key order, pbxproj object graph).
    case equivalent
    /// Applied automatically, but differs from what was committed.
    case wrong
    /// Left for a person (rule says so, or the resolver refused).
    case escalated
    /// A resolution existed but under the confidence threshold — would have been offered, not applied.
    case belowThreshold
    /// Generated file: the benchmark doesn't run generators.
    case needsRegeneration
}

public struct ReplayCase: Sendable, Equatable, Codable {
    public let mergeID: String
    public let path: String
    /// File class (strategy name), "rerere" or "none".
    public let tier: String
    public let verdict: ReplayVerdict
    public let note: String
}

public struct ReplayClassSummary: Sendable, Equatable, Codable {
    public let tier: String
    public let counts: [ReplayVerdict: Int]

    public func count(_ verdict: ReplayVerdict) -> Int { counts[verdict] ?? 0 }
    public var total: Int { counts.values.reduce(0, +) }
    public var applied: Int { count(.exact) + count(.equivalent) + count(.wrong) }
    /// Share of automatically applied files that match what was committed; nil when nothing was applied.
    public var accuracy: Double? { applied == 0 ? nil : Double(count(.exact) + count(.equivalent)) / Double(applied) }
    /// PLAN.md §7 gate: no wrong resolution, and ≥ 99 % of applied ones match.
    public var meetsGate: Bool { count(.wrong) == 0 && (accuracy ?? 1) >= ReplayBenchmark.requiredAccuracy }
}

public struct ReplayReport: Sendable, Equatable, Codable {
    public let repositoryPath: String
    public let since: String
    public let generatedAt: Date
    public let mergesExamined: Int
    public let mergesWithConflicts: Int
    public let cases: [ReplayCase]
    public let durationSeconds: Double

    public var summaries: [ReplayClassSummary] {
        Dictionary(grouping: cases, by: \.tier).map { tier, cases in
            ReplayClassSummary(tier: tier, counts: Dictionary(grouping: cases, by: \.verdict).mapValues(\.count))
        }
        .sorted { $0.total > $1.total }
    }

    public var meetsGate: Bool { summaries.allSatisfy(\.meetsGate) }
}

/// Replays a repository's past merges and scores the automatic tiers against the commits people made.
/// Runs in a private shared clone under the support folder: the repository itself, its hooks, merge drivers and
/// rerere cache are never touched (rerere is off, so the score can't be helped by recorded resolutions).
public struct ReplayBenchmark: Sendable {
    public static let requiredAccuracy = 0.99
    static let evalFolderName = "eval"
    static let cloneFolderName = "clone"
    static let noRerere = ["-c", "rerere.enabled=false"]
    static let jsonExtension = "json"
    static let pbxprojExtension = "pbxproj"
    /// Characters of a differing line quoted in a "wrong" note.
    static let notePreviewLength = 120

    private let git: GitClient
    private let paths: SupportPaths

    public init(git: GitClient = ProcessGitClient(), paths: SupportPaths = SupportPaths()) {
        self.git = git
        self.paths = paths
    }

    public func cloneURL(for repositoryRoot: URL) -> URL {
        paths.repositoryFolder(for: repositoryRoot).appendingPathComponent(Self.evalFolderName, isDirectory: true)
            .appendingPathComponent(Self.cloneFolderName, isDirectory: true)
    }

    /// - Parameters:
    ///   - since: any `git log --since` value, e.g. `6.months`.
    ///   - limit: replay at most this many conflicting merges (newest first).
    ///   - runGenerators: run `regenerate` commands too (needs the repository's toolchain; slow).
    public func run(repositoryRoot: URL, config: RepoConfig, since: String, limit: Int? = nil, runGenerators: Bool = false,
                    progress: @Sendable (String) -> Void = { _ in }) async throws -> ReplayReport {
        let started = Date()
        let clone = try await prepareClone(repositoryRoot)
        let merges = try await mergeCommits(in: repositoryRoot, since: since)
        let resolver = AutoResolver(git: git, config: config)
        var cases: [ReplayCase] = []
        var withConflicts = 0

        for (index, merge) in merges.enumerated() {
            if let limit, withConflicts >= limit { break }
            let predicted = try await git.execute(.mergeTree(target: merge.first, source: merge.second), in: clone)
            guard !predicted.isClean else { continue }
            withConflicts += 1
            progress("[\(index + 1)/\(merges.count)] \(merge.id.prefix(10)): \(predicted.conflictedPaths.count) conflicted files")

            try await checked(["checkout", "--quiet", "--force", "--detach", merge.first], in: clone)
            try await checked(["clean", "-fdxq"], in: clone)
            let result = try await git.run(Self.noRerere + ["merge", "--no-ff", "--no-commit", merge.second], in: clone)
            let output = String(decoding: result.standardOutput + result.standardError, as: UTF8.self)
            let unmerged = try await git.execute(.unmergedPaths, in: clone)
            let resolutions = try await resolver.resolve(conflicted: unmerged, in: clone, mergeOutput: output,
                                                         runGenerators: runGenerators, writeBelowThreshold: true)
            for resolution in resolutions {
                cases.append(try await score(resolution, merge: merge.id, clone: clone))
            }
            _ = try await git.run(["merge", "--abort"], in: clone)
            _ = try await git.run(["reset", "--quiet", "--hard"], in: clone)
        }
        return ReplayReport(repositoryPath: repositoryRoot.path, since: since, generatedAt: Date(), mergesExamined: merges.count,
                            mergesWithConflicts: withConflicts, cases: cases, durationSeconds: Date().timeIntervalSince(started))
    }

    // MARK: - Steps

    /// A `--shared` clone borrows the repository's objects (no copy) and none of its local config or hooks.
    private func prepareClone(_ root: URL) async throws -> URL {
        let clone = cloneURL(for: root)
        if !FileManager.default.fileExists(atPath: clone.appendingPathComponent(".git").path) {
            try FileManager.default.createDirectory(at: clone.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await checked(["clone", "--quiet", "--shared", "--no-checkout", "--", root.path, clone.path], in: root)
        }
        // Merges are scored without git identity checks or signing getting in the way; nothing is committed.
        return clone
    }

    private struct MergeCommit {
        let id: String
        let first: String
        let second: String
    }

    /// Two-parent merges, newest first (octopus merges are skipped).
    private func mergeCommits(in root: URL, since: String) async throws -> [MergeCommit] {
        let result = try await git.run(["log", "--merges", "--since=\(since)", "--format=%H %P"], in: root).requireSuccess()
        return String(decoding: result.standardOutput, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            let ids = line.split(separator: " ").map(String.init)
            return ids.count == 3 ? MergeCommit(id: ids[0], first: ids[1], second: ids[2]) : nil
        }
    }

    private func score(_ resolution: FileResolution, merge: String, clone: URL) async throws -> ReplayCase {
        let tier = resolution.tier.label
        func make(_ verdict: ReplayVerdict, _ note: String) -> ReplayCase {
            ReplayCase(mergeID: merge, path: resolution.path, tier: tier, verdict: verdict, note: note)
        }
        switch resolution.status {
        case .escalated: return make(.escalated, resolution.note)
        case .needsRegeneration: return make(.needsRegeneration, resolution.note)
        case .belowThreshold:
            // Not applied, but scored, so thresholds can be tuned from evidence.
            let (verdict, _) = try await compare(resolution.path, merge: merge, clone: clone, note: resolution.note)
            return make(.belowThreshold, "\(resolution.note); the proposal would have been \(verdict.rawValue)")
        case .applied:
            let (verdict, note) = try await compare(resolution.path, merge: merge, clone: clone, note: resolution.note)
            return make(verdict, note)
        }
    }

    /// The worktree's version of `path` against the committed merge's.
    private func compare(_ path: String, merge: String, clone: URL, note: String) async throws -> (ReplayVerdict, String) {
        let ours = try? Data(contentsOf: clone.appendingPathComponent(path))
        let committedResult = try await git.run(["show", "\(merge):\(path)"], in: clone)
        let committed = committedResult.exitCode == GitExitCode.success ? committedResult.standardOutput : nil
        if ours == committed { return (.exact, note) }
        guard let ours, let committed else {
            return (.wrong, ours == nil ? "deleted, but the merge kept the file" : "kept, but the merge deleted the file")
        }
        if await Self.isEquivalent(ours, committed, path: path) { return (.equivalent, note) }
        return (.wrong, Self.firstDifference(ours, committed))
    }

    static func isEquivalent(_ lhs: Data, _ rhs: Data, path: String) async -> Bool {
        switch (path as NSString).pathExtension {
        case jsonExtension:
            guard let left = try? OrderedJSON(parsing: lhs), let right = try? OrderedJSON(parsing: rhs) else { return false }
            return left.isEquivalent(to: right)
        case pbxprojExtension:
            guard let left = await PBXProjValidator.objects(lhs), let right = await PBXProjValidator.objects(rhs) else { return false }
            return NSDictionary(dictionary: left).isEqual(to: right)
        default:
            return false
        }
    }

    /// "line 12: ours '…' vs committed '…'" — enough to inspect a wrong case.
    static func firstDifference(_ ours: Data, _ committed: Data) -> String {
        let left = TextLines(String(decoding: ours, as: UTF8.self)).lines
        let right = TextLines(String(decoding: committed, as: UTF8.self)).lines
        let index = zip(left, right).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(left.count, right.count)
        let mine = index < left.count ? String(left[index].prefix(notePreviewLength)) : "(end)"
        let theirs = index < right.count ? String(right[index].prefix(notePreviewLength)) : "(end)"
        return "line \(index + 1): merged '\(mine)' vs committed '\(theirs)' (\(left.count) vs \(right.count) lines)"
    }

    private func checked(_ arguments: [String], in directory: URL) async throws {
        try await git.run(arguments, in: directory).requireSuccess()
    }
}
