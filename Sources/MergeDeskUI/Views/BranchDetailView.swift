import MergeDeskCore
import SwiftUI

/// Detail pane for the selected branch: copies, comparisons, unique commits, changed files, overlaps.
struct BranchDetailView: View {
    let model: RepositoryModel

    var body: some View {
        Group {
            switch model.detailState {
            case .idle:
                ContentUnavailableView("Select a branch", systemImage: Symbol.branch,
                                       description: Text("Its commits, files and overlapping branches appear here."))
            case .loading:
                ProgressView("Reading branch…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView("Couldn't read this branch", systemImage: Symbol.warning, description: Text(message))
            case let .loaded(detail):
                BranchDetailContent(detail: detail)
            }
        }
        .accessibilityIdentifier(AccessibilityID.detail)
    }
}

private struct BranchDetailContent: View {
    let detail: BranchDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                header
                comparisons
                if let base = detail.base {
                    commits(base: base)
                    files(base: base)
                    overlaps
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    private var branch: BranchRecord { detail.branch }

    private var header: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            Text(branch.name).font(.title2.bold())
            NoteBadges(notes: BranchNote.notes(for: branch))
            LabeledContent("Compared on", value: "\(branch.tip.shortName) · \(branch.tip.objectID.prefix(Self.shortIDLength))")
            if let local = branch.local, local.objectID != branch.tip.objectID {
                LabeledContent("Local copy", value: "\(local.objectID.prefix(Self.shortIDLength))"
                               + (branch.localSync.map { " · ↑\($0.ahead) ↓\($0.behind) vs remote" } ?? ""))
            }
            LabeledContent("Last commit") {
                Text("\(branch.tip.authorName), ") + Text(branch.tip.committerDate, format: .relative(presentation: .named))
            }
        }
    }

    @ViewBuilder private var comparisons: some View {
        if !branch.integration.isEmpty {
            GroupBox("Against integration branches") {
                VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                    ForEach(branch.integration, id: \.integration) { status in
                        LabeledContent(status.integration) {
                            Text(status.isMerged
                                 ? "Merged (\(status.aheadBehind.behind) behind)"
                                 : "\(status.aheadBehind.ahead) ahead · \(status.aheadBehind.behind) behind")
                                .monospacedDigit()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func commits(base: IntegrationRef) -> some View {
        let more = detail.uniqueCommitsTruncated ? "+" : ""
        return GroupBox("Commits not in \(base.name) (\(detail.uniqueCommits.count)\(more))") {
            if detail.uniqueCommits.isEmpty {
                Text("None — everything is already in \(base.name).").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVStack(alignment: .leading, spacing: Layout.rowSpacing) {
                    ForEach(detail.uniqueCommits) { commit in
                        VStack(alignment: .leading) {
                            Text(commit.subject).lineLimit(2)
                            Text("\(commit.id.prefix(Self.shortIDLength)) · \(commit.authorName) · ")
                                .font(.caption).foregroundStyle(.secondary)
                            + Text(commit.date, format: .relative(presentation: .named))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier(AccessibilityID.detailCommits)
    }

    private func files(base: IntegrationRef) -> some View {
        GroupBox("Files changed since forking from \(base.name) (\(detail.changedFiles.count))") {
            LazyVStack(alignment: .leading, spacing: Layout.rowSpacing) {
                ForEach(detail.changedFiles.prefix(Layout.detailFileLimit), id: \.self) { path in
                    Text(path).font(.callout.monospaced()).lineLimit(1).truncationMode(.head).help(path)
                }
                if detail.changedFiles.count > Layout.detailFileLimit {
                    Text("… and \(detail.changedFiles.count - Layout.detailFileLimit) more (mergedesk show --json lists all)")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(AccessibilityID.detailFiles)
    }

    private var overlaps: some View {
        GroupBox("Active branches changing the same files (\(detail.overlaps.count))") {
            if detail.overlaps.isEmpty {
                Text("No other active branch changed these files since diverging.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVStack(alignment: .leading, spacing: Layout.rowSpacing) {
                    ForEach(detail.overlaps) { overlap in
                        DisclosureGroup("\(overlap.branch) — \(overlap.sharedFiles.count) shared") {
                            VStack(alignment: .leading) {
                                ForEach(overlap.sharedFiles.prefix(Layout.detailFileLimit), id: \.self) { path in
                                    Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .help("Measured from each pair's merge base: only changes made after the two branches diverged count.")
        .accessibilityIdentifier(AccessibilityID.detailOverlaps)
    }

    private static let shortIDLength = 10
}
