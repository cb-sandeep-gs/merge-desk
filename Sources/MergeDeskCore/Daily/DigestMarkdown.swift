import Foundation

/// Renders a digest as Markdown for the file on disk and the CLI.
public enum DigestMarkdown {
    public static func render(_ digest: DailyDigest) -> String {
        let name = URL(fileURLWithPath: digest.repositoryPath).lastPathComponent
        var lines = ["# Merge Desk — \(name)", "", "_\(digest.generatedAt.formatted(date: .complete, time: .shortened))_", ""]
        switch digest.fetch {
        case .fetched: break
        case .skipped: lines += ["> Not fetched: showing the last fetched state.", ""]
        case let .failed(message): lines += ["> ⚠️ Fetch failed (\(message)); showing the last fetched state.", ""]
        }

        lines += section("Rebase today (your branches)", digest.rebaseToday.map { "- `\($0)`" },
                         empty: "Nothing — your branches merge cleanly into \(first(digest)).")
        let newTitle = digest.hasPreviousRun ? "New conflicts since last run" : "Conflicts (first run — nothing to compare yet)"
        lines += section(newTitle, digest.newConflicts.map(conflictLine), empty: "None.")
        if !digest.resolvedConflicts.isEmpty {
            lines += section("Resolved since last run", digest.resolvedConflicts.map { "- \($0.description)" }, empty: "")
        }
        for integration in digest.integrationBranches {
            let conflicts = digest.integrationConflicts.filter { $0.key.other == integration }
            lines += section("Will conflict with \(integration) (\(conflicts.count))", conflicts.map(conflictLine), empty: "None.")
        }
        lines += section("Active branches that conflict with each other (\(digest.pairConflicts.count))",
                         digest.pairConflicts.map(conflictLine), empty: "None.")
        lines += section("Drifting behind \(first(digest)) (\(digest.drifting.count))",
                         digest.drifting.map { "- `\($0.branch)` — \($0.count) commits behind" }, empty: "None.")
        lines += section("Stale (\(digest.stale.count))", digest.stale.map { "- `\($0.branch)` — \($0.count) days idle" }, empty: "None.")
        lines += section("Merged, safe to delete (\(digest.mergedNotDeleted.count))",
                         digest.mergedNotDeleted.map { "- `\($0)`" }, empty: "None.")
        let stats = digest.stats
        lines.append("_\(stats.mergesComputed + stats.mergesFromCache) merges predicted (\(stats.mergesFromCache) cached) "
                     + "in \(String(format: "%.1f", stats.durationSeconds)) s._")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func first(_ digest: DailyDigest) -> String {
        digest.integrationBranches.first ?? "the integration branch"
    }

    private static func conflictLine(_ conflict: DigestConflict) -> String {
        let automatic = conflict.automaticCount > 0 ? ", \(conflict.automaticCount) automatic" : ""
        let more = conflict.fileCount > conflict.files.count ? ", …" : ""
        let files = conflict.files.map { "`\($0)`" }.joined(separator: ", ")
        return "- **\(conflict.key.description)** — \(conflict.fileCount) files\(automatic): \(files)\(more)"
    }

    private static func section(_ title: String, _ items: [String], empty: String) -> [String] {
        ["## \(title)", ""] + (items.isEmpty ? [empty] : items) + [""]
    }
}
