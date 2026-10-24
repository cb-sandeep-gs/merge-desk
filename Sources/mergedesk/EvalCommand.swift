import ArgumentParser
import Foundation
import MergeDeskCore

struct EvalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eval",
        abstract: "Replay past merges and score the automatic resolvers against what people committed.",
        discussion: """
        Works in a private shared clone under Merge Desk's support folder; the repository is never changed.
        Gate (PLAN.md §7): per file class, no wrong resolution and ≥ 99 % of automatic ones matching.
        """
    )

    @OptionGroup var repository: RepositoryOptions
    @Option(name: .long, help: "How far back, as git log --since understands it.")
    var since = "6.months"
    @Option(name: .long, help: "Replay at most this many conflicting merges.")
    var limit: Int?
    @Option(name: .long, help: "Use this .mergedesk.json instead of the repository's (try a config before committing it).")
    var config: String?
    @Flag(name: .long, help: "Also run regenerate commands (needs the repository's toolchain; slow).")
    var runGenerators = false
    @Flag(name: .long, help: "Print the full report as JSON.")
    var json = false

    func run() async throws {
        let git = ProcessGitClient()
        let root = try await repository.repositoryRoot(using: git)
        let repoConfig: RepoConfig
        if let config {
            let url = CommandPath.absoluteDirectory(config)
            repoConfig = try ConfigLoader.decode(try Data(contentsOf: url), path: url.path).0
        } else {
            repoConfig = try ConfigLoader.load(repositoryRoot: root).config
        }
        let quiet = json
        let report = try await ReplayBenchmark(git: git).run(repositoryRoot: root, config: repoConfig, since: since, limit: limit,
                                                             runGenerators: runGenerators) {
            if !quiet { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        }
        if json {
            print(String(decoding: try OutputJSON.encode(report), as: UTF8.self))
            return
        }
        print(EvalText.render(report))
        if !report.meetsGate { throw ExitCode.failure }
    }
}

enum EvalText {
    private static let columns = ["CLASS", "FILES", "EXACT", "EQUIV", "WRONG", "ESCAL", "<THRESH", "REGEN", "ACCURACY", "GATE"]
    private static let percent = 100.0
    private static let wrongListLimit = 20

    static func render(_ report: ReplayReport) -> String {
        var rows = [columns]
        for summary in report.summaries {
            let accuracy = summary.accuracy.map { String(format: "%.1f%%", $0 * percent) } ?? "—"
            rows.append([summary.tier, "\(summary.total)", "\(summary.count(.exact))", "\(summary.count(.equivalent))",
                         "\(summary.count(.wrong))", "\(summary.count(.escalated))", "\(summary.count(.belowThreshold))",
                         "\(summary.count(.needsRegeneration))", accuracy, summary.meetsGate ? "pass" : "FAIL"])
        }
        let widths = (0..<columns.count).map { column in rows.map { $0[column].count }.max() ?? 0 }
        var lines = ["Replayed \(report.mergesWithConflicts) conflicting merges of \(report.mergesExamined) since \(report.since) "
                     + String(format: "in %.0f s", report.durationSeconds), ""]
        lines += rows.map { row in
            row.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "  ")
        }
        let wrong = report.cases.filter { $0.verdict == .wrong }
        if !wrong.isEmpty {
            lines.append("\nWrong (\(wrong.count)):")
            lines += wrong.prefix(wrongListLimit).map { "  \($0.mergeID.prefix(10)) \($0.path) [\($0.tier)] \($0.note)" }
        }
        lines.append("\nGate: \(report.meetsGate ? "PASS" : "FAIL") (no wrong resolutions, ≥ 99 % of automatic ones exact or equivalent)")
        return lines.joined(separator: "\n")
    }
}
