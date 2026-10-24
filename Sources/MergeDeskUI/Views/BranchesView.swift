import MergeDeskCore
import SwiftUI

/// The Branches table with its filter bar, status line and loading / empty / error states.
struct BranchesView: View {
    @Bindable var model: RepositoryModel

    var body: some View {
        VStack(spacing: 0) {
            banners
            content
            Divider()
            statusLine
        }
        .navigationTitle(model.repository.displayName)
        .navigationSubtitle(model.repository.path)
        .searchable(text: $model.filter.searchText, placement: .toolbar, prompt: "Branch or author")
        .toolbar { toolbar }
    }

    // MARK: - States

    @ViewBuilder private var content: some View {
        switch model.inventoryState {
        case .idle, .loading:
            ProgressView("Reading branches…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't read this repository", systemImage: Symbol.warning)
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.refresh() }
            }
        case .loaded:
            if model.rows.isEmpty {
                emptyResult
            } else {
                table
            }
        }
    }

    @ViewBuilder private var emptyResult: some View {
        if model.totalBranchCount == 0 {
            ContentUnavailableView("No branches", systemImage: Symbol.branch,
                                   description: Text("This repository has no branches yet."))
        } else if !model.filter.searchText.isEmpty {
            ContentUnavailableView.search(text: model.filter.searchText)
        } else {
            ContentUnavailableView {
                Label("No \(model.filter.scope.title.lowercased()) branches", systemImage: Symbol.branch)
            } actions: {
                Button("Show All") {
                    model.filter = BranchFilter(searchText: model.filter.searchText)
                }
            }
        }
    }

    private var table: some View {
        let names = model.integrationNames
        return Table(model.rows, selection: $model.selectedBranch, sortOrder: $model.sortOrder) {
            TableColumn("Branch", value: \.name) { row in
                Text(row.name).lineLimit(1).truncationMode(.middle).help(row.name)
            }
            .width(min: Layout.branchColumnMin, ideal: Layout.branchColumnIdeal, max: Layout.branchColumnMax)
            TableColumn("Where", value: \.presenceSortKey) { row in
                Text(row.presenceText).foregroundStyle(.secondary)
                    .help("Local = only on this Mac · Remote = only on the remote · Both = in both places")
            }
            .width(min: Layout.narrowColumnMin, ideal: Layout.whereColumnIdeal)
            TableColumn("Last commit", value: \.lastCommit) { row in
                Text(row.lastCommit, format: .relative(presentation: .named))
                    .help(row.lastCommit.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: Layout.narrowColumnMin, ideal: Layout.dateColumnIdeal)
            TableColumn("Author", value: \.author) { row in
                Text(row.author).lineLimit(1)
            }
            .width(min: Layout.narrowColumnMin, ideal: Layout.authorColumnIdeal)
            TableColumn(Self.comparisonTitle(names.first), value: \.firstSortKey) { row in
                Text(row.first.text).monospacedDigit()
            }
            .width(min: Layout.narrowColumnMin, ideal: Layout.comparisonColumnIdeal)
            TableColumn(Self.comparisonTitle(names.dropFirst().first), value: \.secondSortKey) { row in
                Text(row.second.text).monospacedDigit()
            }
            .width(min: Layout.narrowColumnMin, ideal: Layout.comparisonColumnIdeal)
            TableColumn("Notes") { row in
                NoteBadges(notes: row.notes, compact: true)
            }
            .width(min: Layout.notesColumnMin, ideal: Layout.notesColumnIdeal)
        }
        .accessibilityIdentifier(AccessibilityID.branchTable)
    }

    private static func comparisonTitle(_ integration: String?) -> String {
        integration.map { "vs \($0)" } ?? BranchRow.missingValue
    }

    // MARK: - Chrome

    @ViewBuilder private var banners: some View {
        if let inventory = model.inventory, !inventory.missingIntegrationBranches.isEmpty {
            Banner(text: "Not found: \(inventory.missingIntegrationBranches.joined(separator: ", ")). "
                   + "Check integrationBranches in \(MergeDeskConstants.configFileName).")
        }
        ForEach(model.configWarnings, id: \.self) { warning in
            Banner(text: "\(MergeDeskConstants.configFileName): \(warning)")
        }
    }

    private var statusLine: some View {
        HStack(spacing: Layout.rowSpacing) {
            if let inventory = model.inventory {
                Text("\(model.rows.count) of \(inventory.branches.count) branches · ↑ ahead ↓ behind · updated")
                Text(inventory.generatedAt, style: .relative)
                Text("ago")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, Layout.rowSpacing)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.statusLine)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("Show", selection: $model.filter.scope) {
                ForEach(BranchFilter.Scope.allCases, id: \.self) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .help("Mine: your last commit · Active: unmerged, recent · Stale: no commits for a while · "
                  + "Merged: safe to delete · Unpushed: commits only on this Mac")
            .accessibilityIdentifier(AccessibilityID.scopePicker)
        }
        ToolbarItem {
            Menu {
                Button("Any prefix") { model.filter.prefix = nil }
                Divider()
                ForEach(model.availablePrefixes, id: \.self) { prefix in
                    Button(prefix) { model.filter.prefix = prefix }
                }
            } label: {
                Label(model.filter.prefix ?? "Prefix", systemImage: Symbol.prefix)
            }
            .help("Only branches starting with a prefix")
            .accessibilityIdentifier(AccessibilityID.prefixMenu)
        }
        ToolbarItem {
            Button("Refresh", systemImage: Symbol.refresh) { model.refresh() }
                .keyboardShortcut("r")
                .disabled(model.inventoryState.isLoading)
                .help("Re-read branches (⌘R). Run git fetch first to see new remote work.")
                .accessibilityIdentifier(AccessibilityID.refresh)
        }
    }
}

/// A one-line warning strip above the table.
struct Banner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: Symbol.warning)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, Layout.rowSpacing * 2)
            .background(.yellow.opacity(Layout.badgeBackgroundOpacity))
    }
}

/// Small coloured labels for branch notes.
struct NoteBadges: View {
    let notes: [BranchNote]
    /// Short labels for the table column; the detail pane shows the full text.
    var compact = false

    var body: some View {
        HStack(spacing: Layout.rowSpacing) {
            ForEach(notes, id: \.self) { note in
                Text(compact ? note.shortText : note.text)
                    .font(.caption)
                    .lineLimit(1)
                    .help(note.text)
                    .padding(.horizontal, Layout.badgeHorizontalPadding)
                    .padding(.vertical, Layout.badgeVerticalPadding)
                    .background(Self.color(note).opacity(Layout.badgeBackgroundOpacity),
                                in: RoundedRectangle(cornerRadius: Layout.badgeCornerRadius))
                    .foregroundStyle(Self.color(note))
            }
        }
    }

    static func color(_ note: BranchNote) -> Color {
        switch note {
        case .integration, .protected: return .blue
        case .stale: return .orange
        case .merged: return .green
        case .neverPushed, .unpushed: return .purple
        case .toPull: return .secondary
        }
    }
}
