import Foundation

/// Posts a short alert. The app uses macOS notifications; the CLI falls back to AppleScript.
public protocol Notifier: Sendable {
    func notify(title: String, body: String) async
}

/// Does nothing (tests, `--no-notify`).
public struct SilentNotifier: Notifier {
    public init() {}
    public func notify(title: String, body: String) async {}
}

/// `display notification` through osascript: works from a plain command-line process with no app bundle.
public struct AppleScriptNotifier: Notifier {
    static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")

    public init() {}

    public func notify(title: String, body: String) async {
        let script = "display notification \(Self.quoted(body)) with title \(Self.quoted(title))"
        // Best effort: a notification that can't be shown must never fail the daily run.
        _ = try? await ProcessRunner.run(executableURL: Self.osascript, arguments: ["-e", script],
                                         directory: FileManager.default.temporaryDirectory,
                                         environment: ProcessInfo.processInfo.environment)
    }

    /// AppleScript string literal with quotes and backslashes escaped.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Files a daily run wrote.
public struct DailyRunResult: Sendable {
    public let digest: DailyDigest
    public let markdownURL: URL
    public let digestURL: URL
}

/// The daily job for one repository: fetch → inventory → predictions (integration + matrix) → digest → notify.
/// It fetches remote-tracking refs and writes only into Merge Desk's support folder; it never merges, pushes or
/// touches the working tree.
public struct DailyRunner: Sendable {
    public static let snapshotFileName = "last-run.json"
    public static let latestDigestFileName = "latest-digest.json"
    static let digestsFolderName = "digests"
    static let digestDateFormat = "yyyy-MM-dd"
    /// Branches named in a notification before "and N more".
    static let notificationBranchLimit = 3

    private let git: GitClient
    private let paths: SupportPaths
    private let notifier: Notifier

    public init(git: GitClient = ProcessGitClient(), paths: SupportPaths = SupportPaths(), notifier: Notifier = AppleScriptNotifier()) {
        self.git = git
        self.paths = paths
        self.notifier = notifier
    }

    public func run(repositoryRoot: URL, fetch shouldFetch: Bool = true, now: Date = Date()) async throws -> DailyRunResult {
        let fetch = shouldFetch ? await fetch(repositoryRoot) : .skipped
        let config = try ConfigLoader.load(repositoryRoot: repositoryRoot).config
        let inventory = try await InventoryBuilder(git: git).build(repositoryRoot: repositoryRoot, config: config, now: now)
        let predictor = Predictor(git: git, store: PredictionStore(paths: paths, repositoryRoot: repositoryRoot))
        let predictions = try await predictor.predict(inventory: inventory, config: config, repositoryRoot: repositoryRoot,
                                                      scope: .integrationAndMatrix, now: now)
        let snapshot = DailySnapshot(inventory: inventory, predictions: predictions)

        let folder = paths.repositoryFolder(for: repositoryRoot)
        let snapshotURL = folder.appendingPathComponent(Self.snapshotFileName)
        let previous = try? Self.decoder.decode(DailySnapshot.self, from: Data(contentsOf: snapshotURL))
        let digest = DigestBuilder.build(current: snapshot, previous: previous, config: config, fetch: fetch)

        let digests = folder.appendingPathComponent(Self.digestsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: digests, withIntermediateDirectories: true)
        let markdownURL = digests.appendingPathComponent("\(Self.dayStamp(now)).md")
        try Data(DigestMarkdown.render(digest).utf8).write(to: markdownURL, options: .atomic)
        let digestURL = folder.appendingPathComponent(Self.latestDigestFileName)
        try Self.encoder.encode(digest).write(to: digestURL, options: .atomic)
        try Self.encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)

        if let message = Self.notification(for: digest) {
            await notifier.notify(title: message.title, body: message.body)
        }
        return DailyRunResult(digest: digest, markdownURL: markdownURL, digestURL: digestURL)
    }

    /// The latest digest saved for a repository, if any run happened.
    public static func latestDigest(repositoryRoot: URL, paths: SupportPaths = SupportPaths()) -> DailyDigest? {
        let url = paths.repositoryFolder(for: repositoryRoot).appendingPathComponent(latestDigestFileName)
        return try? decoder.decode(DailyDigest.self, from: Data(contentsOf: url))
    }

    /// Notify only about something new or something for the user to do — a quiet day stays quiet.
    static func notification(for digest: DailyDigest) -> (title: String, body: String)? {
        guard !digest.isQuiet else { return nil }
        let name = URL(fileURLWithPath: digest.repositoryPath).lastPathComponent
        var parts: [String] = []
        if !digest.newConflicts.isEmpty {
            let names = digest.newConflicts.prefix(notificationBranchLimit).map(\.key.description)
            let extra = digest.newConflicts.count - notificationBranchLimit
            let more = extra > 0 ? " and \(extra) more" : ""
            parts.append("\(digest.newConflicts.count) new conflict\(digest.newConflicts.count == 1 ? "" : "s"): "
                         + names.joined(separator: ", ") + more)
        }
        if !digest.rebaseToday.isEmpty {
            parts.append("Rebase today: " + digest.rebaseToday.prefix(notificationBranchLimit).joined(separator: ", "))
        }
        return ("Merge Desk — \(name)", parts.joined(separator: ". "))
    }

    /// Fetch failures (offline, VPN down) are reported in the digest, not thrown: yesterday's refs are still useful.
    private func fetch(_ root: URL) async -> FetchOutcome {
        do {
            let result = try await git.run(["fetch", "--prune", "--quiet"], in: root)
            return result.exitCode == GitExitCode.success ? .fetched : .failed(result.errorText)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = digestDateFormat
        return formatter.string(from: date)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
