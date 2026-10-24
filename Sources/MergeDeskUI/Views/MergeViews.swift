import AppKit
import MergeDeskCore
import SwiftUI

/// "Merge <branch> into …": target, strategy, fetch, and a live conflict preview before anything runs.
struct MergeSheet: View {
    let model: RepositoryModel
    let source: String
    @Environment(\.dismiss) private var dismiss
    @State private var target: String = ""
    @State private var strategy: MergeStrategy = .mergeCommit
    @State private var fetch = true
    @State private var preview: MergePrediction?
    @State private var isPreviewing = false

    private var targets: [String] {
        guard let inventory = model.inventory else { return [] }
        let integration = inventory.integrationRefs.map(\.name)
        let others = inventory.branches.map(\.name).filter { !integration.contains($0) }
        return (integration + others).filter { $0 != source }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Merge", value: source)
                Picker("Into", selection: $target) {
                    ForEach(targets, id: \.self) { Text($0).tag($0) }
                }
                Picker("As", selection: $strategy) {
                    ForEach(MergeStrategy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Fetch first", isOn: $fetch)
            }
            Section("Before you start") {
                if model.sessions.isProtected(target) {
                    Label("\(target) is protected: the merge goes to a new branch and a pull request.", systemImage: Symbol.merge)
                }
                if isPreviewing {
                    ProgressView().controlSize(.small)
                } else if let preview {
                    Label(preview.isClean ? "Merges cleanly" : "Predicted: \(preview.summary)",
                          systemImage: preview.isClean ? Symbol.clean : Symbol.conflict)
                        .foregroundStyle(preview.isClean ? Palette.clean : Palette.conflict)
                    ForEach(preview.conflicts.prefix(Layout.overlapFilePreview)) { conflict in
                        HStack {
                            Text(conflict.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                            Spacer()
                            RouteBadge(route: conflict.route)
                        }
                    }
                }
                Text("Runs in a separate worktree. Nothing in your checkout or branches changes until you choose Apply.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: Layout.settingsWidth)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start Merge") {
                    let (source, target, strategy, fetch) = (source, target, strategy, fetch)
                    model.contentMode = .merges
                    dismiss()
                    Task { await model.sessions.startMerge(source: source, target: target, strategy: strategy, fetch: fetch) }
                }
                .disabled(target.isEmpty)
                .accessibilityIdentifier(AccessibilityID.startMerge)
            }
        }
        .onAppear { if target.isEmpty { target = targets.first ?? "" } }
        .task(id: target) { await loadPreview() }
    }

    private func loadPreview() async {
        guard !target.isEmpty, let inventory = model.inventory else { return }
        isPreviewing = true
        preview = await model.sessions.preview(source: source, target: target, inventory: inventory)
        isPreviewing = false
    }
}

/// The Merges view: sessions newest first; selecting one shows it in the detail pane.
struct SessionsListView: View {
    @Bindable var sessions: SessionsModel

    var body: some View {
        if sessions.sessions.isEmpty {
            ContentUnavailableView("No merges yet", systemImage: Symbol.merge,
                                   description: Text("Select a branch and choose Merge… to start one."))
        } else {
            List(sessions.sessions, selection: $sessions.selectedSessionID) { session in
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(session.source) → \(session.target)").lineLimit(1).truncationMode(.middle)
                        Text("\(session.strategy.title) · \(session.createdAt.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    StateBadge(state: session.state)
                }
                .tag(session.id)
            }
            .accessibilityIdentifier(AccessibilityID.sessionList)
        }
    }
}

/// A session's state, colour-coded.
struct StateBadge: View {
    let state: SessionState

    var body: some View {
        Text(state.title)
            .font(.caption)
            .padding(.horizontal, Layout.badgeHorizontalPadding)
            .padding(.vertical, Layout.badgeVerticalPadding)
            .background(color.opacity(Layout.badgeBackgroundOpacity), in: RoundedRectangle(cornerRadius: Layout.badgeCornerRadius))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case .resolving: return Palette.conflict
        case .ready, .applied: return .blue
        case .pushed, .pullRequestOpened: return Palette.clean
        case .aborted, .undone: return .secondary
        case .planned, .preflight, .merging, .verifying: return .purple
        }
    }
}

/// Detail pane for a session: what happened, what's left to do, and the buttons to do it.
struct SessionDetailView: View {
    @Bindable var sessions: SessionsModel
    @State private var pendingConfirmation: SessionAction?

    var body: some View {
        if let session = sessions.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    header(session)
                    if let error = sessions.errorMessage ?? session.lastError {
                        Label(error, systemImage: Symbol.warning).foregroundStyle(Palette.conflict).textSelection(.enabled)
                    }
                    ForEach(session.warnings, id: \.self) { Label($0, systemImage: Symbol.warning).foregroundStyle(.secondary) }
                    if session.state == .resolving { conflicts(session) }
                    actions(session)
                    timeline(session)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .confirmationDialog(confirmationTitle(session), isPresented: Binding(
                get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } }
            ), titleVisibility: .visible) {
                if let action = pendingConfirmation {
                    Button(action == .push ? "Push" : "Push & Open Pull Request") {
                        Task { await sessions.run(action, on: session, confirmed: true) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This changes the remote. It's never a force-push.")
            }
        } else {
            ContentUnavailableView("Select a merge", systemImage: Symbol.merge)
        }
    }

    private func header(_ session: MergeSession) -> some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            HStack {
                Text("\(session.source) → \(session.target)").font(.title2.bold()).textSelection(.enabled)
                Spacer()
                StateBadge(state: session.state)
            }
            Text("\(session.strategy.title) · session \(session.shortID)").foregroundStyle(.secondary)
            if let branch = session.pullRequestBranch {
                LabeledContent("Pull request branch", value: branch)
            }
            if let result = session.resultID {
                LabeledContent("Merge commit", value: String(result.prefix(SessionView.shortIDLength)))
            }
            if case let .movedBranch(branch, previous, backup) = session.applied {
                LabeledContent("Moved", value: "\(branch) from \(previous.prefix(SessionView.shortIDLength))")
                LabeledContent("Backup", value: backup).textSelection(.enabled)
            }
            if let url = session.pullRequestURL.flatMap(URL.init(string:)) {
                Link("Open pull request page", destination: url)
            }
        }
    }

    private func conflicts(_ session: MergeSession) -> some View {
        GroupBox("Resolve these files in the worktree (\(session.conflictedFiles.count))") {
            VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                ForEach(session.conflictedFiles, id: \.self) { path in
                    HStack {
                        Text(path).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                        Spacer()
                        if let worktree = session.worktreePath {
                            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: worktree).appendingPathComponent(path)) }
                        }
                    }
                }
                if let worktree = session.worktreePath {
                    Button("Reveal Worktree in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree)])
                    }
                }
                Text("Edit each file, remove the <<<<<<< / >>>>>>> markers, then choose Mark Resolved & Continue.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actions(_ session: MergeSession) -> some View {
        HStack {
            ForEach(SessionAction.available(for: session), id: \.self) { action in
                Button(action.title) {
                    if action.needsConfirmation {
                        pendingConfirmation = action
                    } else {
                        Task { await sessions.run(action, on: session) }
                    }
                }
                .disabled(sessions.isBusy)
                .accessibilityIdentifier("\(AccessibilityID.sessionActionPrefix)\(action.rawValue)")
            }
            if sessions.isBusy { ProgressView().controlSize(.small) }
        }
    }

    private func timeline(_ session: MergeSession) -> some View {
        GroupBox("History") {
            VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                ForEach(Array(session.history.enumerated()), id: \.offset) { _, event in
                    HStack {
                        Text(event.state.title)
                        if let note = event.note { Text(note).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        Spacer()
                        Text(event.at.formatted(date: .omitted, time: .standard)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func confirmationTitle(_ session: MergeSession) -> String {
        pendingConfirmation == .push
            ? "Push \(session.target) to the remote?"
            : "Push \(session.pullRequestBranch ?? "the branch") and open a pull request into \(session.target)?"
    }
}

enum SessionView {
    static let shortIDLength = 10
}
