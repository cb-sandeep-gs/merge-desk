import Foundation

/// Which tier decided a file (PLAN.md §6.4).
public enum ResolutionTier: Sendable, Equatable, Codable {
    /// Tier 1: a file-class rule.
    case fileRule(FileStrategy)
    /// Tier 2: git rerere replayed a resolution recorded earlier for the identical conflict.
    case rerere
    /// No rule and nothing recorded: the history engine (MD-5) or a person.
    case unhandled
    /// A person resolved it in Merge Desk.
    case manual

    public var label: String {
        switch self {
        case let .fileRule(strategy): return strategy.rawValue
        case .rerere: return "rerere"
        case .unhandled: return "none"
        case .manual: return "you"
        }
    }
}

/// What happened to one conflicted file.
public struct FileResolution: Sendable, Equatable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable {
        /// Resolved and staged.
        case applied
        /// A resolution exists but its confidence is below the configured threshold: a person confirms it.
        case belowThreshold
        /// Needs the generator, which wasn't run (evaluation) or failed.
        case needsRegeneration
        /// A person resolves it.
        case escalated
    }

    public var id: String { path }
    public let path: String
    public let tier: ResolutionTier
    public let status: Status
    public let confidence: Confidence?
    public let note: String
}

/// Tier 1 + Tier 2 for the conflicts `git merge` left in a worktree. Resolved files are staged; everything
/// else stays conflicted (with markers) for a person.
public struct AutoResolver: Sendable {
    /// git's message when rerere reuses a recorded resolution: `Resolved '<path>' using previous resolution.`
    static let rererePrefix = "Resolved '"
    static let rerereSuffix = "' using previous resolution."
    static let envURL = URL(fileURLWithPath: "/usr/bin/env")

    private let git: GitClient
    private let config: RepoConfig

    public init(git: GitClient, config: RepoConfig) {
        self.git = git
        self.config = config
    }

    /// - Parameters:
    ///   - mergeOutput: stdout + stderr of the `git merge`, to see which files rerere replayed.
    ///   - runGenerators: false in the replay benchmark by default (generators are slow and need the repo's toolchain).
    ///   - writeBelowThreshold: also write (not stage) resolutions under the threshold — the benchmark scores them.
    public func resolve(conflicted: [String], in worktree: URL, mergeOutput: String, runGenerators: Bool,
                        writeBelowThreshold: Bool = false) async throws -> [FileResolution] {
        let replayed = Self.rerereResolvedPaths(mergeOutput)
        var resolutions: [FileResolution] = []
        var regenerate: [[String]: [String]] = [:]

        for path in conflicted {
            guard let rule = config.fileClass(for: path) else {
                if replayed.contains(path) {
                    try await stage(path, in: worktree)
                    resolutions.append(FileResolution(path: path, tier: .rerere, status: .applied, confidence: .high,
                                                      note: "replayed a recorded resolution"))
                } else {
                    resolutions.append(FileResolution(path: path, tier: .unhandled, status: .escalated, confidence: nil,
                                                      note: "no file rule; needs the history engine or a person"))
                }
                continue
            }
            let input = try await stages(of: path, in: worktree)
            let resolver = FileResolvers.resolver(for: rule, regenerateCommand: config.regenerateCommand)
            let tier = ResolutionTier.fileRule(rule.strategy)
            switch try await resolver.resolve(input, git: git) {
            case let .resolved(data, confidence, note):
                let threshold = config.autoApplyMinConfidence.threshold(for: rule.strategy)
                if confidence >= threshold {
                    try write(data, to: path, in: worktree)
                    try await stage(path, in: worktree)
                    resolutions.append(FileResolution(path: path, tier: tier, status: .applied, confidence: confidence, note: note))
                } else {
                    if writeBelowThreshold { try write(data, to: path, in: worktree) }
                    let reason = "\(note) — \(confidence.rawValue) confidence, below the \(threshold.rawValue) threshold"
                    resolutions.append(FileResolution(path: path, tier: tier, status: .belowThreshold, confidence: confidence,
                                                      note: reason))
                }
            case let .regenerate(data, command):
                // Not staged yet: the index keeps the conflict, so a failed generator can restore the markers.
                try write(data, to: path, in: worktree)
                regenerate[command, default: []].append(path)
            case let .escalate(reason):
                resolutions.append(FileResolution(path: path, tier: tier, status: .escalated, confidence: nil, note: reason))
            }
        }
        for (command, paths) in regenerate.sorted(by: { $0.key.joined() < $1.key.joined() }) {
            resolutions += try await regenerateFiles(paths, command: command, in: worktree, run: runGenerators)
        }
        return resolutions.sorted { $0.path < $1.path }
    }

    /// Runs one generator once for all its files. If it fails (or isn't run), those files go back to conflicted.
    private func regenerateFiles(_ paths: [String], command: [String], in worktree: URL, run: Bool) async throws -> [FileResolution] {
        let label = command.joined(separator: " ")
        if run {
            let result = try await ProcessRunner.run(executableURL: Self.envURL, arguments: command, directory: worktree,
                                                     environment: ProcessInfo.processInfo.environment)
            if result.exitCode == GitExitCode.success {
                // The generator may rewrite any generated file: stage everything it produced.
                _ = try await git.run(["add", "--all"], in: worktree)
                return paths.map { FileResolution(path: $0, tier: .fileRule(.regenerate), status: .applied, confidence: .high,
                                                  note: "regenerated by \(label)") }
            }
            for path in paths { _ = try await git.run(["checkout", "--merge", "--", path], in: worktree) }
            return paths.map { FileResolution(path: $0, tier: .fileRule(.regenerate), status: .needsRegeneration, confidence: nil,
                                              note: "\(label) failed: \(result.errorText.prefix(200))") }
        }
        for path in paths { _ = try await git.run(["checkout", "--merge", "--", path], in: worktree) }
        return paths.map { FileResolution(path: $0, tier: .fileRule(.regenerate), status: .needsRegeneration, confidence: nil,
                                          note: "rebuilt by \(label) (not run here)") }
    }

    /// Base, ours and theirs from the index's conflict stages 1, 2 and 3 (missing stage = absent on that side).
    func stages(of path: String, in worktree: URL) async throws -> ConflictInput {
        func stage(_ number: Int) async throws -> Data? {
            let result = try await git.run(["show", ":\(number):\(path)"], in: worktree)
            return result.exitCode == GitExitCode.success ? result.standardOutput : nil
        }
        return ConflictInput(path: path, base: try await stage(1), ours: try await stage(2), theirs: try await stage(3))
    }

    private func write(_ data: Data?, to path: String, in worktree: URL) throws {
        let file = worktree.appendingPathComponent(path)
        if let data {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// `add --all` also records a deletion.
    private func stage(_ path: String, in worktree: URL) async throws {
        try await git.run(["add", "--all", "--", path], in: worktree).requireSuccess()
    }

    static func rerereResolvedPaths(_ output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix(rererePrefix), line.hasSuffix(rerereSuffix) else { return nil }
            return String(line.dropFirst(rererePrefix.count).dropLast(rerereSuffix.count))
        })
    }
}
