import Foundation

/// How sure the resolution engine is about a resolution. Ordered: `low < medium < high`.
public enum Confidence: String, Codable, Sendable, Comparable, CaseIterable {
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rank < rhs.rank }
}

/// Tier-1 strategy for a class of files (see PLAN.md §6.4). Files that match no rule go to the history engine.
public enum FileStrategy: String, Codable, Sendable, CaseIterable {
    /// Never merge bytes; take either side, then run the repo's `regenerateCommand`.
    case regenerate
    /// Structural 3-way merge of an Xcode project's object graph.
    case pbxproj
    /// Keep both sides' new entries (release notes, changelogs).
    case unionEntries
    /// Key-wise 3-way JSON merge.
    case jsonKeys
    /// Always hand to a person.
    case escalate
}

/// One `fileClasses` entry: first matching rule wins.
public struct FileClassRule: Codable, Sendable, Equatable {
    public let glob: GlobPattern
    public let strategy: FileStrategy
    /// For `regenerate`: the generator for this class (argv, run in the merge worktree); falls back to the
    /// repo-wide `regenerateCommand`. Lets different generated families use different generators.
    public let command: [String]?

    public init(glob: GlobPattern, strategy: FileStrategy, command: [String]? = nil) {
        self.glob = glob
        self.strategy = strategy
        self.command = command
    }
}

/// Minimum confidence before a resolution is applied without a person, overall and per strategy.
public struct ConfidenceThresholds: Codable, Sendable, Equatable {
    public let `default`: Confidence
    public let byStrategy: [FileStrategy: Confidence]

    public init(default: Confidence, byStrategy: [FileStrategy: Confidence] = [:]) {
        self.default = `default`
        self.byStrategy = byStrategy
    }

    public func threshold(for strategy: FileStrategy?) -> Confidence {
        strategy.flatMap { byStrategy[$0] } ?? self.default
    }

    private enum CodingKeys: String, CodingKey {
        case `default`
        case byStrategy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.default = try container.decodeIfPresent(Confidence.self, forKey: .default)
            ?? RepoConfig.defaults.autoApplyMinConfidence.default
        // JSON object keys are strings; map them onto the strategy enum so a typo is a decoding error, not a no-op.
        let raw = try container.decodeIfPresent([String: Confidence].self, forKey: .byStrategy) ?? [:]
        var mapped: [FileStrategy: Confidence] = [:]
        for (key, value) in raw {
            guard let strategy = FileStrategy(rawValue: key) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .byStrategy, in: container,
                    debugDescription: "unknown strategy '\(key)'; expected one of \(FileStrategy.allCases.map(\.rawValue))"
                )
            }
            mapped[strategy] = value
        }
        self.byStrategy = mapped
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.default, forKey: .default)
        let raw = Dictionary(uniqueKeysWithValues: byStrategy.map { ($0.key.rawValue, $0.value) })
        if !raw.isEmpty { try container.encode(raw, forKey: .byStrategy) }
    }
}

/// Everything repository-specific, read from `.mergedesk.json`. Missing keys fall back to `RepoConfig.defaults`,
/// so a repository works with no file at all.
public struct RepoConfig: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    /// Branches every other branch is compared and predicted against, in display order (e.g. develop, main).
    public var integrationBranches: [String]
    /// Remote whose branches are the team's shared state; its tips are what branches are compared on.
    public var primaryRemote: String
    /// Branch-name globs that can only receive changes through a pull request.
    public var protectedBranches: [GlobPattern]
    /// Days without a commit after which a branch counts as stale.
    public var staleDays: Int
    /// An active branch this many commits behind the first integration branch is "drifting" in the daily digest.
    public var driftBehindThreshold: Int
    /// Prefixes of "active work" branches for the branch × branch matrix; empty = every non-integration branch.
    public var activeBranchPrefixes: [String]
    public var fileClasses: [FileClassRule]
    /// argv run once after `regenerate` files are taken (e.g. `["python3", "./mercury", "fix"]`).
    public var regenerateCommand: [String]?
    /// argv lists run by the verification gate before a merge is marked ready.
    public var verifyCommands: [[String]]
    public var autoApplyMinConfidence: ConfidenceThresholds

    public init(
        schemaVersion: Int,
        integrationBranches: [String],
        primaryRemote: String,
        protectedBranches: [GlobPattern],
        staleDays: Int,
        driftBehindThreshold: Int,
        activeBranchPrefixes: [String],
        fileClasses: [FileClassRule],
        regenerateCommand: [String]?,
        verifyCommands: [[String]],
        autoApplyMinConfidence: ConfidenceThresholds
    ) {
        self.schemaVersion = schemaVersion
        self.integrationBranches = integrationBranches
        self.primaryRemote = primaryRemote
        self.protectedBranches = protectedBranches
        self.staleDays = staleDays
        self.driftBehindThreshold = driftBehindThreshold
        self.activeBranchPrefixes = activeBranchPrefixes
        self.fileClasses = fileClasses
        self.regenerateCommand = regenerateCommand
        self.verifyCommands = verifyCommands
        self.autoApplyMinConfidence = autoApplyMinConfidence
    }

    /// Defaults agreed in PLAN.md §0: develop + main, 21-day staleness, only high-confidence auto-apply.
    /// The globs are literals covered by tests (`testDefaultsAreValidAndMatchThePlan`).
    public static let defaults = RepoConfig(
        schemaVersion: MergeDeskConstants.supportedConfigSchemaVersion,
        integrationBranches: ["develop", "main"],
        primaryRemote: "origin",
        protectedBranches: ["main", "develop", "release/*"].map { GlobPattern(staticPattern: $0) },
        staleDays: 21,
        driftBehindThreshold: 50,
        activeBranchPrefixes: [],
        fileClasses: [
            FileClassRule(glob: GlobPattern(staticPattern: "**/*.pbxproj"), strategy: .pbxproj),
            FileClassRule(glob: GlobPattern(staticPattern: "**/Package.resolved"), strategy: .escalate),
        ],
        regenerateCommand: nil,
        verifyCommands: [],
        autoApplyMinConfidence: ConfidenceThresholds(default: .high)
    )

    /// Keys this version understands; anything else in the file is reported as a warning (likely a typo).
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, integrationBranches, primaryRemote, protectedBranches, staleDays, driftBehindThreshold, activeBranchPrefixes
        case fileClasses, regenerateCommand, verifyCommands, autoApplyMinConfidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.defaults
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? fallback.schemaVersion
        integrationBranches = try container.decodeIfPresent([String].self, forKey: .integrationBranches) ?? fallback.integrationBranches
        primaryRemote = try container.decodeIfPresent(String.self, forKey: .primaryRemote) ?? fallback.primaryRemote
        protectedBranches = try container.decodeIfPresent([GlobPattern].self, forKey: .protectedBranches) ?? fallback.protectedBranches
        staleDays = try container.decodeIfPresent(Int.self, forKey: .staleDays) ?? fallback.staleDays
        driftBehindThreshold = try container.decodeIfPresent(Int.self, forKey: .driftBehindThreshold)
            ?? fallback.driftBehindThreshold
        activeBranchPrefixes = try container.decodeIfPresent([String].self, forKey: .activeBranchPrefixes) ?? fallback.activeBranchPrefixes
        fileClasses = try container.decodeIfPresent([FileClassRule].self, forKey: .fileClasses) ?? fallback.fileClasses
        regenerateCommand = try container.decodeIfPresent([String].self, forKey: .regenerateCommand) ?? fallback.regenerateCommand
        verifyCommands = try container.decodeIfPresent([[String]].self, forKey: .verifyCommands) ?? fallback.verifyCommands
        autoApplyMinConfidence = try container.decodeIfPresent(ConfidenceThresholds.self, forKey: .autoApplyMinConfidence)
            ?? fallback.autoApplyMinConfidence
    }

    // MARK: - Queries used by later phases

    /// First matching file-class rule for a repository-relative path, or nil (→ history engine).
    public func fileClass(for path: String) -> FileClassRule? {
        fileClasses.first { $0.glob.matches(path) }
    }

    /// Whether a branch name (without remote, e.g. `release/1.2`) may only be changed through a PR.
    public func isProtected(branch: String) -> Bool {
        protectedBranches.contains { $0.matches(branch) }
    }

    /// Whether a branch counts as active work for the branch × branch matrix.
    public func isActiveWork(branch: String) -> Bool {
        guard !integrationBranches.contains(branch) else { return false }
        return activeBranchPrefixes.isEmpty || activeBranchPrefixes.contains { branch.hasPrefix($0) }
    }

    /// Whether a branch whose last commit is at `lastCommit` is stale at `now`.
    public func isStale(lastCommit: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastCommit) > TimeInterval(staleDays) * Self.secondsPerDay
    }

    private static let secondsPerDay: TimeInterval = 24 * 60 * 60
}
