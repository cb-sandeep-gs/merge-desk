import Foundation

/// A GitHub repository identified from a git remote URL.
public struct GitHubRepository: Sendable, Equatable {
    public let host: String
    public let owner: String
    public let name: String

    static let githubHostMarker = "github"
    static let gitSuffix = ".git"

    /// Parses `git@github.com:owner/repo.git`, `ssh://git@github.com/owner/repo.git` and
    /// `https://github.com/owner/repo(.git)`. Nil for anything that isn't a GitHub host.
    public init?(remoteURL: String) {
        let text = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostAndPath: (String, String)
        if let url = URL(string: text), let host = url.host, url.scheme != nil {
            hostAndPath = (host, url.path)
        } else if let at = text.firstIndex(of: "@"), let colon = text[at...].firstIndex(of: ":") {
            // scp-like syntax: user@host:owner/repo.git
            hostAndPath = (String(text[text.index(after: at)..<colon]), String(text[text.index(after: colon)...]))
        } else {
            return nil
        }
        let (host, rawPath) = hostAndPath
        guard host.lowercased().contains(Self.githubHostMarker) else { return nil }
        var path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(Self.gitSuffix) { path.removeLast(Self.gitSuffix.count) }
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        self.host = host
        self.owner = String(parts[0])
        self.name = String(parts[1])
    }

    /// The "open a pull request" page comparing `head` with `base`.
    public func compareURL(base: String, head: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
        guard let base = base.addingPercentEncoding(withAllowedCharacters: allowed),
              let head = head.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://\(host)/\(owner)/\(name)/compare/\(base)...\(head)?expand=1")
    }
}

/// CI state of a pull request, summarised from GitHub's check runs and statuses.
public enum CheckSummary: String, Sendable, Codable {
    case passing
    case failing
    case pending
    case none
}

/// An open pull request, as `gh pr list --json` reports it.
public struct PullRequestInfo: Sendable, Equatable, Codable, Identifiable {
    public var id: Int { number }
    public let number: Int
    public let title: String
    public let url: String
    public let headRefName: String
    public let baseRefName: String
    public let isDraft: Bool
    public let checks: CheckSummary
}

public enum GitHubError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case unavailable
    case commandFailed(String)

    public var description: String {
        switch self {
        case .unavailable: return "The GitHub CLI (gh) isn't installed or signed in (brew install gh && gh auth login)."
        case let .commandFailed(message): return "gh failed: \(message)"
        }
    }

    public var errorDescription: String? { description }
}

/// Optional adapter over the `gh` CLI (PLAN.md §0 decision 4). Merge Desk stores no tokens: `gh` owns sign-in.
/// Everything that uses it has a fallback (compare URL, hidden columns).
public struct GitHubCLI: Sendable {
    /// Where Homebrew and the official installer put `gh`.
    static let searchPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    static let listLimit = 200
    static let listFields = "number,title,url,headRefName,baseRefName,isDraft,statusCheckRollup"

    public let executableURL: URL?

    public init(executableURL: URL? = GitHubCLI.locate()) {
        self.executableURL = executableURL
    }

    public static func locate() -> URL? {
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gh" }
        return (searchPaths + pathEntries).first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Installed and signed in.
    public func isAvailable(in root: URL) async -> Bool {
        guard let result = try? await run(["auth", "status"], in: root) else { return false }
        return result.exitCode == GitExitCode.success
    }

    public func createPullRequest(base: String, head: String, title: String, body: String, in root: URL) async throws -> URL {
        let result = try await run(["pr", "create", "--base", base, "--head", head, "--title", title, "--body", body], in: root)
        guard result.exitCode == GitExitCode.success else { throw GitHubError.commandFailed(result.errorText) }
        // gh prints the new pull request's URL as its last line.
        let lines = String(decoding: result.standardOutput, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard let last = lines.last, let url = URL(string: String(last)) else {
            throw GitHubError.commandFailed("no pull request URL in gh output")
        }
        return url
    }

    public func openPullRequests(in root: URL) async throws -> [PullRequestInfo] {
        let result = try await run(["pr", "list", "--state", "open", "--limit", "\(Self.listLimit)", "--json", Self.listFields], in: root)
        guard result.exitCode == GitExitCode.success else { throw GitHubError.commandFailed(result.errorText) }
        return try Self.parsePullRequests(result.standardOutput)
    }

    private func run(_ arguments: [String], in root: URL) async throws -> GitResult {
        guard let executableURL else { throw GitHubError.unavailable }
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        return try await ProcessRunner.run(executableURL: executableURL, arguments: arguments, directory: root,
                                           environment: environment)
    }

    // MARK: - Parsing

    private struct RawPullRequest: Decodable {
        let number: Int
        let title: String
        let url: String
        let headRefName: String
        let baseRefName: String
        let isDraft: Bool
        let statusCheckRollup: [RawCheck]?
    }

    /// A check run (`status` + `conclusion`) or a commit status (`state`).
    private struct RawCheck: Decodable {
        let status: String?
        let conclusion: String?
        let state: String?
    }

    private enum CheckWords {
        static let completed = "COMPLETED"
        static let success = ["SUCCESS", "NEUTRAL", "SKIPPED"]
        static let failure = ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"]
    }

    static func parsePullRequests(_ data: Data) throws -> [PullRequestInfo] {
        try JSONDecoder().decode([RawPullRequest].self, from: data).map { raw in
            PullRequestInfo(number: raw.number, title: raw.title, url: raw.url, headRefName: raw.headRefName,
                            baseRefName: raw.baseRefName, isDraft: raw.isDraft, checks: summarize(raw.statusCheckRollup ?? []))
        }
    }

    /// Any failure → failing; else anything unfinished → pending; else passing; no checks → none.
    private static func summarize(_ checks: [RawCheck]) -> CheckSummary {
        guard !checks.isEmpty else { return .none }
        let outcomes = checks.map { check -> String? in
            if let state = check.state { return state.uppercased() }
            guard check.status?.uppercased() == CheckWords.completed else { return nil }
            return check.conclusion?.uppercased()
        }
        if outcomes.contains(where: { $0.map(CheckWords.failure.contains) ?? false }) { return .failing }
        if outcomes.contains(where: { $0 == nil || !CheckWords.success.contains($0 ?? "") }) { return .pending }
        return .passing
    }
}
