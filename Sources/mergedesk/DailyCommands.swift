import ArgumentParser
import Foundation
import MergeDeskCore

struct PredictCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "predict",
        abstract: "Predict merge conflicts without touching any checkout: branches vs integration branches, and vs each other."
    )

    @OptionGroup var repository: RepositoryOptions
    @Flag(name: .long, help: "Skip the branch × branch matrix (faster).")
    var integrationOnly = false
    @Flag(name: .long, help: "Print JSON instead of text.")
    var json = false

    func run() async throws {
        let git = ProcessGitClient()
        let root = try await repository.repositoryRoot(using: git)
        let config = try ConfigLoader.load(repositoryRoot: root).config
        let inventory = try await InventoryBuilder(git: git).build(repositoryRoot: root, config: config)
        let report = try await Predictor(git: git, store: PredictionStore(paths: SupportPaths(), repositoryRoot: root))
            .predict(inventory: inventory, config: config, repositoryRoot: root,
                     scope: integrationOnly ? .integration : .integrationAndMatrix)
        if json {
            print(String(decoding: try OutputJSON.encode(report), as: UTF8.self))
        } else {
            print(PredictionText.render(report))
        }
    }
}

enum PredictionText {
    static func render(_ report: PredictionReport) -> String {
        var lines: [String] = []
        for integration in report.integration {
            let conflicting = integration.conflicting
            lines.append("Into \(integration.integration): \(conflicting.count) of \(integration.branches.count) branches will conflict")
            for branch in conflicting {
                guard let prediction = branch.prediction else { continue }
                lines.append("  \(branch.branch) — \(prediction.summary)")
                lines += prediction.conflicts.map { "      \($0.path)  [\($0.route.label)]" }
            }
            lines.append("")
        }
        if let matrix = report.matrix {
            lines.append("Between \(matrix.branches.count) active branches: \(matrix.conflictingPairs.count) conflicting pairs")
            for pair in matrix.conflictingPairs {
                lines.append("  \(pair.first) ↔ \(pair.second) — \(pair.prediction.summary)")
            }
            if !matrix.omittedBranches.isEmpty {
                lines.append("  (\(matrix.omittedBranches.count) older active branches left out: limit \(Predictor.maxMatrixBranches))")
            }
            lines.append("")
        }
        let stats = report.stats
        lines.append("\(stats.mergesComputed + stats.mergesFromCache) merges (\(stats.mergesFromCache) cached) in "
                     + String(format: "%.1f s", stats.durationSeconds))
        return lines.joined(separator: "\n")
    }
}

struct DailyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daily",
        abstract: "Fetch, predict and write today's digest; notify when something new needs attention."
    )

    @OptionGroup var repository: RepositoryOptions
    @Flag(name: .long, help: "Run for every repository added in the Merge Desk app.")
    var all = false
    @Flag(name: .long, help: "Don't run git fetch first.")
    var noFetch = false
    @Flag(name: .long, help: "Don't show a notification.")
    var noNotify = false

    func run() async throws {
        let roots: [URL]
        if all {
            roots = try RepositoryRegistry().load().map(\.url)
            if roots.isEmpty { Report.info("No repositories added in Merge Desk yet.") }
        } else {
            roots = [try await repository.repositoryRoot(using: ProcessGitClient())]
        }
        let notifier: Notifier = noNotify ? SilentNotifier() : AppleScriptNotifier()
        var failures = 0
        for root in roots {
            do {
                let result = try await DailyRunner(notifier: notifier).run(repositoryRoot: root, fetch: !noFetch)
                Report.ok("\(root.lastPathComponent): \(DailySummary.line(result.digest)) → \(result.markdownURL.path)")
            } catch {
                // One broken repository must not stop the others.
                Report.fail("\(root.lastPathComponent): \(error.localizedDescription)")
                failures += 1
            }
        }
        if failures > 0 { throw ExitCode.failure }
    }
}

enum DailySummary {
    /// Branch names shown inline before "+N more".
    static let summaryBranchLimit = 5

    static func line(_ digest: DailyDigest) -> String {
        var parts = ["\(digest.newConflicts.count) new conflicts",
                     "\(digest.integrationConflicts.count) vs integration",
                     "\(digest.pairConflicts.count) between branches"]
        if !digest.rebaseToday.isEmpty {
            let shown = digest.rebaseToday.prefix(summaryBranchLimit).joined(separator: ", ")
            let more = digest.rebaseToday.count > summaryBranchLimit ? " +\(digest.rebaseToday.count - summaryBranchLimit) more" : ""
            parts.append("rebase today: \(shown)\(more)")
        }
        if case let .failed(message) = digest.fetch { parts.append("fetch failed: \(message)") }
        return parts.joined(separator: " · ")
    }
}

struct DigestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "digest", abstract: "Print the latest daily digest.")

    @OptionGroup var repository: RepositoryOptions

    func run() async throws {
        let root = try await repository.repositoryRoot(using: ProcessGitClient())
        guard let digest = DailyRunner.latestDigest(repositoryRoot: root) else {
            Report.info("No digest yet — run `mergedesk daily`.")
            return
        }
        print(DigestMarkdown.render(digest))
    }
}

struct ScheduleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schedule",
        abstract: "Run `mergedesk daily --all` every day at a set time (a per-user LaunchAgent; nothing runs as root)."
    )

    @Option(name: .customLong("at"), help: "24-hour time, e.g. 09:30.")
    var time: String?
    @Flag(name: .long, help: "Remove the schedule.")
    var remove = false
    @Flag(name: .long, help: "Run the scheduled job now (through launchd).")
    var runNow = false

    func run() async throws {
        let schedule = DailySchedule()
        if remove {
            try await schedule.remove()
            Report.ok("Daily run removed.")
            return
        }
        if let time {
            guard let time = DailyTime(time) else { throw ValidationError("--at expects HH:MM (24-hour), e.g. 09:30") }
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            let program = [CommandPath.absoluteDirectory(executable.path).path, "daily", "--all"]
            try await schedule.install(program: program, at: time)
            Report.ok("Daily run at \(time): \(program.joined(separator: " "))")
            Report.info("Log: \(schedule.logURL.path)")
        }
        if runNow {
            try await schedule.runNow()
            Report.ok("Started; see \(schedule.logURL.path)")
        }
        if time == nil, !runNow {
            if let installed = schedule.installed() {
                Report.ok("Daily run at \(installed.time): \(installed.programArguments.joined(separator: " "))")
            } else {
                Report.info("No daily run scheduled (mergedesk schedule --at 09:30).")
            }
        }
    }
}
