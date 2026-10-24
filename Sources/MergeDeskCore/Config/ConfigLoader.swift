import Foundation

/// A problem in `.mergedesk.json`. Errors block use of the file; warnings are shown but don't.
public struct ConfigIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }

    public let severity: Severity
    /// Dotted location, e.g. `fileClasses[2].glob`.
    public let field: String
    public let message: String

    public init(_ severity: Severity, field: String, _ message: String) {
        self.severity = severity
        self.field = field
        self.message = message
    }

    public var description: String { "\(severity.rawValue): \(field): \(message)" }
}

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case malformed(path: String, reason: String)
    case invalid(path: String, issues: [ConfigIssue])

    public var description: String {
        switch self {
        case let .unreadable(path, reason): return "Cannot read \(path): \(reason)"
        case let .malformed(path, reason): return "\(path) is not valid: \(reason)"
        case let .invalid(path, issues):
            return "\(path) has \(issues.count) problem(s):\n" + issues.map { "  - \($0)" }.joined(separator: "\n")
        }
    }
}

/// The configuration actually in force for a repository, and where it came from.
public struct LoadedConfig: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case file(URL)
        /// No `.mergedesk.json` in the repository; built-in defaults apply.
        case defaults
    }

    public let config: RepoConfig
    public let source: Source
    public let warnings: [ConfigIssue]
}

public enum ConfigLoader {
    /// Reads `<repositoryRoot>/.mergedesk.json`, or returns defaults when the file does not exist.
    /// Throws `ConfigError` when the file exists but is unreadable, malformed or invalid.
    public static func load(repositoryRoot: URL, fileManager: FileManager = .default) throws -> LoadedConfig {
        let url = repositoryRoot.appendingPathComponent(MergeDeskConstants.configFileName)
        guard fileManager.fileExists(atPath: url.path) else {
            return LoadedConfig(config: .defaults, source: .defaults, warnings: [])
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        let (config, warnings) = try decode(data, path: url.path)
        return LoadedConfig(config: config, source: .file(url), warnings: warnings)
    }

    /// Decodes and validates config bytes. Exposed for tests and for `mergedesk config validate --file`.
    public static func decode(_ data: Data, path: String) throws -> (RepoConfig, [ConfigIssue]) {
        let config: RepoConfig
        do {
            config = try JSONDecoder().decode(RepoConfig.self, from: data)
        } catch let error as DecodingError {
            throw ConfigError.malformed(path: path, reason: describe(error))
        } catch {
            throw ConfigError.malformed(path: path, reason: error.localizedDescription)
        }
        let issues = unknownKeyWarnings(data) + validate(config)
        let errors = issues.filter { $0.severity == .error }
        guard errors.isEmpty else { throw ConfigError.invalid(path: path, issues: errors) }
        return (config, issues)
    }

    /// Semantic checks the type system can't express.
    public static func validate(_ config: RepoConfig) -> [ConfigIssue] {
        validateSchema(config) + validateBranches(config) + validateCommands(config) + validateFileClasses(config)
    }

    private static func validateSchema(_ config: RepoConfig) -> [ConfigIssue] {
        let supported = MergeDeskConstants.supportedConfigSchemaVersion
        if config.schemaVersion > supported {
            return [.init(.error, field: "schemaVersion",
                          "version \(config.schemaVersion) needs a newer Merge Desk (this build reads up to \(supported))")]
        }
        if config.schemaVersion < supported {
            return [.init(.error, field: "schemaVersion", "must be \(supported) or later")]
        }
        return []
    }

    private static func validateBranches(_ config: RepoConfig) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        if config.integrationBranches.isEmpty {
            issues.append(.init(.error, field: "integrationBranches", "list at least one branch (e.g. develop or main)"))
        }
        for (index, branch) in config.integrationBranches.enumerated() where branch.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(.error, field: "integrationBranches[\(index)]", "branch name is empty"))
        }
        if Set(config.integrationBranches).count != config.integrationBranches.count {
            issues.append(.init(.error, field: "integrationBranches", "contains duplicates"))
        }
        if !staleDaysRange.contains(config.staleDays) {
            let range = "\(staleDaysRange.lowerBound) and \(staleDaysRange.upperBound)"
            issues.append(.init(.error, field: "staleDays", "must be between \(range)"))
        }
        for (index, prefix) in config.activeBranchPrefixes.enumerated() where prefix.isEmpty {
            issues.append(.init(.error, field: "activeBranchPrefixes[\(index)]", "prefix is empty"))
        }
        for branch in config.integrationBranches where !config.isProtected(branch: branch) {
            issues.append(.init(.warning, field: "protectedBranches",
                                "integration branch '\(branch)' is not protected, so merges into it can be pushed directly"))
        }
        return issues
    }

    private static func validateCommands(_ config: RepoConfig) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        let usesRegenerate = config.fileClasses.contains { $0.strategy == .regenerate }
        if let command = config.regenerateCommand, command.isEmpty || command[0].isEmpty {
            issues.append(.init(.error, field: "regenerateCommand", "must name a program, e.g. [\"python3\", \"./tool\", \"fix\"]"))
        } else if usesRegenerate && config.regenerateCommand == nil {
            issues.append(.init(.error, field: "regenerateCommand", "required because a file class uses the 'regenerate' strategy"))
        }
        for (index, command) in config.verifyCommands.enumerated() where command.isEmpty || command[0].isEmpty {
            issues.append(.init(.error, field: "verifyCommands[\(index)]", "must name a program"))
        }
        return issues
    }

    private static func validateFileClasses(_ config: RepoConfig) -> [ConfigIssue] {
        // Later rules can never match a path an earlier identical glob already claimed.
        var seenGlobs = Set<String>()
        return config.fileClasses.enumerated().compactMap { index, rule in
            guard !seenGlobs.insert(rule.glob.pattern).inserted else { return nil }
            return ConfigIssue(.warning, field: "fileClasses[\(index)].glob",
                               "'\(rule.glob)' repeats an earlier rule and will never be used")
        }
    }

    /// One day to ten years: anything outside is almost certainly a typo.
    static let staleDaysRange = 1...3650

    private static func unknownKeyWarnings(_ data: Data) -> [ConfigIssue] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let known = Set(RepoConfig.CodingKeys.allCases.map(\.rawValue))
        return object.keys.filter { !known.contains($0) && !$0.hasPrefix(commentKeyPrefix) }.sorted().map {
            ConfigIssue(.warning, field: $0, "unknown key (ignored) — check the spelling")
        }
    }

    /// Keys starting with `$` are allowed for schema references and notes, e.g. `"$schema"`, `"$comment"`.
    private static let commentKeyPrefix = "$"

    /// Turns a `DecodingError` into "field.path: what went wrong" for people, not Swift internals.
    static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            let text = codingPath.map { key in key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)" }.joined()
            return text.hasPrefix(".") ? String(text.dropFirst()) : (text.isEmpty ? "(root)" : text)
        }
        switch error {
        case let .typeMismatch(type, context):
            return "\(path(context.codingPath)): expected \(type)"
        case let .valueNotFound(type, context):
            return "\(path(context.codingPath)): missing \(type)"
        case let .keyNotFound(key, context):
            return "\(path(context.codingPath + [key])): required"
        case let .dataCorrupted(context):
            let reason = (context.underlyingError as NSError?)?.localizedDescription ?? context.debugDescription
            return "\(path(context.codingPath)): \(context.codingPath.isEmpty ? reason : context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}
