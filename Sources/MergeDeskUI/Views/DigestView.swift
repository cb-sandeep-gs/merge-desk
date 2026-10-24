import MergeDeskCore
import SwiftUI

/// The latest daily digest for the repository, with "Run Now".
struct DigestView: View {
    let model: RepositoryModel

    var body: some View {
        Group {
            if let digest = model.digest {
                ScrollView {
                    VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                        header(digest)
                        DigestSections(digest: digest)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
            } else {
                ContentUnavailableView {
                    Label("No digest yet", systemImage: Symbol.digest)
                } description: {
                    Text("The daily run fetches, predicts every merge and lists what changed since the last run.")
                } actions: {
                    runButton
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.digest)
    }

    private func header(_ digest: DailyDigest) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading) {
                Text("Daily digest").font(.title2.bold())
                Text(digest.generatedAt.formatted(date: .complete, time: .shortened)).foregroundStyle(.secondary)
                if case let .failed(message) = digest.fetch {
                    Label("Fetch failed (\(message)); showing the last fetched state.", systemImage: Symbol.warning)
                        .foregroundStyle(Palette.conflict)
                }
                if let error = model.dailyError {
                    Label(error, systemImage: Symbol.warning).foregroundStyle(Palette.conflict)
                }
            }
            Spacer()
            runButton
        }
    }

    private var runButton: some View {
        Button {
            model.runDaily()
        } label: {
            if model.isRunningDaily {
                ProgressView().controlSize(.small)
            } else {
                Label("Fetch & Run Now", systemImage: Symbol.refresh)
            }
        }
        .disabled(model.isRunningDaily)
        .help("git fetch, then predict every merge and write today's digest (no merges, no pushes)")
        .accessibilityIdentifier(AccessibilityID.runDaily)
    }
}

/// The digest's sections; shared by the window and (summarised) by the menu bar.
struct DigestSections: View {
    let digest: DailyDigest

    var body: some View {
        let first = digest.integrationBranches.first ?? "the integration branch"
        section("Rebase today (your branches)", items: digest.rebaseToday.map { ($0, nil) },
                empty: "Nothing — your branches merge cleanly into \(first).")
        section(digest.hasPreviousRun ? "New since last run" : "Conflicts (first run — nothing to compare yet)",
                conflicts: digest.newConflicts)
        if !digest.resolvedConflicts.isEmpty {
            section("Resolved since last run", items: digest.resolvedConflicts.map { ($0.description, nil) }, empty: "")
        }
        ForEach(digest.integrationBranches, id: \.self) { integration in
            section("Will conflict with \(integration)",
                    conflicts: digest.integrationConflicts.filter { $0.key.other == integration })
        }
        section("Active branches that conflict with each other", conflicts: digest.pairConflicts)
        section("Drifting behind \(first)", items: digest.drifting.map { ($0.branch, "\($0.count) behind") }, empty: "None.")
        section("Stale", items: digest.stale.map { ($0.branch, "\($0.count) days idle") }, empty: "None.")
        section("Merged, safe to delete", items: digest.mergedNotDeleted.map { ($0, nil) }, empty: "None.")
        Text(Self.statsLine(digest.stats)).font(.caption).foregroundStyle(.secondary)
    }

    static func statsLine(_ stats: PredictionStats) -> String {
        let seconds = stats.durationSeconds.formatted(.number.precision(.fractionLength(1)))
        return "\(stats.mergesComputed + stats.mergesFromCache) merges predicted (\(stats.mergesFromCache) cached) in \(seconds) s"
    }

    private func section(_ title: String, conflicts: [DigestConflict]) -> some View {
        GroupBox("\(title) (\(conflicts.count))") {
            VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                if conflicts.isEmpty {
                    Text("None.").foregroundStyle(.secondary)
                }
                ForEach(conflicts) { conflict in
                    VStack(alignment: .leading) {
                        HStack {
                            Text(conflict.key.description).bold()
                            Spacer()
                            Text(conflict.automaticCount > 0
                                 ? "\(conflict.fileCount) files, \(conflict.automaticCount) automatic"
                                 : "\(conflict.fileCount) files")
                                .foregroundStyle(Palette.conflict)
                        }
                        Text(conflict.files.joined(separator: " · ") + (conflict.fileCount > conflict.files.count ? " …" : ""))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, items: [(String, String?)], empty: String) -> some View {
        GroupBox("\(title) (\(items.count))") {
            VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                if items.isEmpty { Text(empty).foregroundStyle(.secondary) }
                ForEach(items, id: \.0) { item in
                    HStack {
                        Text(item.0)
                        Spacer()
                        if let detail = item.1 { Text(detail).foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
