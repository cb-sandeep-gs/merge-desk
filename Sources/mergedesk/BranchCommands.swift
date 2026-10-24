import ArgumentParser
import Foundation
import MergeDeskCore

extension BranchFilter.Scope: ExpressibleByArgument {}

/// Loads config + inventory for a repository; shared by `list` and `show`.
private struct InventoryContext {
    let root: URL
    let config: RepoConfig
    let inventory: RepositoryInventory

    static func load(_ repository: RepositoryOptions) async throws -> InventoryContext {
        let git = ProcessGitClient()
        let root = try await repository.repositoryRoot(using: git)
        let loaded = try ConfigLoader.load(repositoryRoot: root)
        loaded.warnings.forEach { Report.warn($0.description) }
        let inventory = try await InventoryBuilder(git: git).build(repositoryRoot: root, config: loaded.config)
        return InventoryContext(root: root, config: loaded.config, inventory: inventory)
    }
}

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List branches with ahead/behind against each integration branch, staleness and merge state."
    )

    @OptionGroup var repository: RepositoryOptions
    @Option(name: .long, help: "Which branches: \(BranchFilter.Scope.allCases.map(\.rawValue).joined(separator: ", ")).")
    var filter: BranchFilter.Scope = .all
    @Option(name: .long, help: "Only branches whose name or last author contains this text.")
    var search: String = ""
    @Option(name: .long, help: "Only branches starting with this prefix, e.g. feature/.")
    var prefix: String?
    @Flag(name: .long, help: "Print JSON instead of a table.")
    var json = false

    func run() async throws {
        let context = try await InventoryContext.load(repository)
        let filter = BranchFilter(scope: filter, searchText: search, prefix: prefix)
        // Only the will-conflict scope needs predictions (integration only; cached on disk after the first run).
        let predictions = filter.scope == .willConflict
            ? try await Predictor(store: PredictionStore(paths: SupportPaths(), repositoryRoot: context.root))
                .predict(inventory: context.inventory, config: context.config, repositoryRoot: context.root, scope: .integration)
            : nil
        let inventory = context.inventory.filtered(by: filter, predictions: predictions)
        if json {
            print(String(decoding: try OutputJSON.encode(inventory), as: UTF8.self))
            return
        }
        for missing in inventory.missingIntegrationBranches {
            Report.warn("integration branch '\(missing)' not found locally or on \(context.config.primaryRemote)")
        }
        print(BranchTable.render(inventory))
        print("\n\(inventory.branches.count) of \(context.inventory.branches.count) branches"
              + " · compared on \(context.config.primaryRemote)'s copies · ↑ ahead ↓ behind")
    }
}

struct ShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "One branch: its copies, ahead/behind, unique commits, changed files and overlapping branches."
    )

    @OptionGroup var repository: RepositoryOptions
    @Argument(help: "Branch name without the remote, e.g. feature/x.")
    var branch: String
    @Option(name: .long, help: "Most commits to list.")
    var maxCommits = BranchDetailLoader.defaultMaxCommits
    @Option(name: .long, help: "Most files to print per list in text output (JSON is always complete).")
    var maxFiles = BranchDetailText.defaultMaxFiles
    @Flag(name: .long, help: "Print JSON instead of text.")
    var json = false

    func validate() throws {
        guard maxCommits > 0 else { throw ValidationError("--max-commits must be positive") }
        guard maxFiles > 0 else { throw ValidationError("--max-files must be positive") }
    }

    func run() async throws {
        let context = try await InventoryContext.load(repository)
        let detail: BranchDetail
        do {
            detail = try await BranchDetailLoader().load(
                branchNamed: branch, from: context.inventory, repositoryRoot: context.root, maxCommits: maxCommits
            )
        } catch let error as BranchDetailError {
            // A wrong branch name isn't a usage mistake: report it without the usage banner.
            Report.fail(error.description)
            throw ExitCode.failure
        }
        if json {
            print(String(decoding: try OutputJSON.encode(detail), as: UTF8.self))
        } else {
            print(BranchDetailText.render(detail, now: context.inventory.generatedAt, maxFiles: maxFiles))
        }
    }
}

/// Fixed-width text table of branches.
enum BranchTable {
    private static let maxAuthorWidth = 18
    private static let columnGap = "  "

    static func render(_ inventory: RepositoryInventory) -> String {
        let integrationNames = inventory.integrationRefs.map(\.name)
        let header = ["BRANCH", "WHERE", "AGE", "AUTHOR"] + integrationNames.map { $0.uppercased() } + ["NOTES"]
        let rows = inventory.branches.map { branch -> [String] in
            [branch.name, branch.presence.rawValue,
             AgeFormatting.short(from: branch.tip.committerDate, to: inventory.generatedAt),
             String(branch.tip.authorName.prefix(maxAuthorWidth))]
                + integrationNames.map { name in branch.status(against: name).map(BranchText.aheadBehind) ?? "—" }
                + [BranchText.notes(branch).joined(separator: ", ")]
        }
        return format([header] + rows)
    }

    private static func format(_ table: [[String]]) -> String {
        guard let columns = table.first?.count else { return "" }
        let widths = (0..<columns).map { column in table.map { $0[column].count }.max() ?? 0 }
        return table.map { row in
            row.enumerated().map { column, cell in
                column == columns - 1 ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: columnGap)
        }.joined(separator: "\n")
    }
}

/// Wording shared by the table and the detail text.
enum BranchText {
    static func aheadBehind(_ status: IntegrationStatus) -> String {
        status.isMerged && status.aheadBehind.behind == 0
            ? "merged"
            : "↑\(status.aheadBehind.ahead) ↓\(status.aheadBehind.behind)"
    }

    static func notes(_ branch: BranchRecord) -> [String] {
        var notes: [String] = []
        if branch.isIntegration { notes.append("integration") }
        if branch.isProtected { notes.append("protected") }
        if branch.isStale { notes.append("stale") }
        if !branch.mergedInto.isEmpty, !branch.isIntegration {
            notes.append("merged into \(branch.mergedInto.joined(separator: "+"))")
        }
        if branch.presence == .local { notes.append("never pushed") }
        if let sync = branch.localSync {
            if sync.ahead > 0 { notes.append("\(sync.ahead) unpushed") }
            if sync.behind > 0 { notes.append("\(sync.behind) to pull") }
        }
        return notes
    }
}

enum BranchDetailText {
    /// Long-lived branches can touch thousands of files; the text view shows the first ones and a count.
    static let defaultMaxFiles = 50
    private static let labelWidth = 9

    static func render(_ detail: BranchDetail, now: Date, maxFiles: Int) -> String {
        let branch = detail.branch
        var lines = ["\(branch.name)  (\(branch.presence.rawValue))"]
        let tip = branch.tip
        lines.append("  tip       \(tip.shortName) \(tip.objectID.prefix(10)) · \(tip.authorName) · "
                     + AgeFormatting.short(from: tip.committerDate, to: now) + " ago")
        if let local = branch.local, local.objectID != tip.objectID {
            let sync = branch.localSync.map { " (↑\($0.ahead) ↓\($0.behind) vs remote)" } ?? ""
            lines.append("  local     \(local.objectID.prefix(10))\(sync)")
        }
        for status in branch.integration {
            let label = status.integration.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            lines.append("  \(label) \(BranchText.aheadBehind(status))")
        }
        let notes = BranchText.notes(branch)
        if !notes.isEmpty { lines.append("  notes     \(notes.joined(separator: ", "))") }

        guard let base = detail.base else { return lines.joined(separator: "\n") }
        let more = detail.uniqueCommitsTruncated ? "+" : ""
        lines.append("\nCommits not in \(base.name) (\(detail.uniqueCommits.count)\(more))")
        lines += detail.uniqueCommits.map { "  \($0.id.prefix(10))  \($0.subject)  — \($0.authorName)" }
        lines.append("\nFiles changed since forking from \(base.name) (\(detail.changedFiles.count))")
        lines += capped(detail.changedFiles.map { "  \($0)" }, maxFiles)
        lines.append("\nOther active branches changing the same files (\(detail.overlaps.count))")
        lines += capped(detail.overlaps.map { overlap in
            let shown = overlap.sharedFiles.prefix(maxFiles).joined(separator: ", ")
            let more = overlap.sharedFiles.count > maxFiles ? " … +\(overlap.sharedFiles.count - maxFiles) more" : ""
            return "  \(overlap.branch) (\(overlap.sharedFiles.count)): \(shown)\(more)"
        }, maxFiles)
        return lines.joined(separator: "\n")
    }

    private static func capped(_ lines: [String], _ limit: Int) -> [String] {
        lines.count > limit ? Array(lines.prefix(limit)) + ["  … +\(lines.count - limit) more (use --max-files or --json)"] : lines
    }
}

/// Stable JSON for scripts: sorted keys, ISO-8601 dates.
enum OutputJSON {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}
