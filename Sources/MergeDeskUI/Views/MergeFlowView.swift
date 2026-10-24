import AppKit
import MergeDeskCore
import SwiftUI

/// The Merge tab: choose two branches, press Merge, resolve what's left, apply. Written for people who don't
/// know git: every label uses branch names, never "ours/theirs".
struct MergeFlowView: View {
    @Bindable var flow: MergeFlowModel
    @State private var confirmPublish = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                    Text("Merge branches").font(.title.bold())
                    Text("Bring the changes from one branch into another. Your checkout is never touched, "
                         + "and nothing changes in your branches until you choose Apply.")
                        .foregroundStyle(.secondary)
                }
                if let error = flow.errorMessage {
                    Label(error, systemImage: Symbol.warning)
                        .foregroundStyle(Palette.conflict)
                        .padding(Layout.cardPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.conflict.opacity(Layout.badgeBackgroundOpacity),
                                    in: RoundedRectangle(cornerRadius: Layout.cardCornerRadius))
                        .textSelection(.enabled)
                }
                chooseCard
                if flow.step == .choose, flow.into != nil, flow.from != nil { previewCard }
                if flow.step != .choose { progressCard }
            }
            .padding(Layout.cardPadding * 2)
            .frame(maxWidth: Layout.mergeFlowMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: Binding(get: { flow.resolvingPath != nil }, set: { if !$0 { flow.closeResolver() } })) {
            ResolveSheet(flow: flow)
        }
        .confirmationDialog(publishQuestion, isPresented: $confirmPublish, titleVisibility: .visible) {
            Button(flow.session?.viaPullRequest == true ? "Push & Open Pull Request" : "Push") {
                Task { await flow.publish() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This sends the merge to the shared repository. It's never a force-push.")
        }
        .accessibilityIdentifier(AccessibilityID.mergeFlow)
    }

    private var intoName: String { flow.session?.target ?? flow.into ?? "the branch" }
    private var fromName: String { flow.session?.source ?? flow.from ?? "the other branch" }

    // MARK: - Step 1: choose

    private var chooseCard: some View {
        Card(number: 1, title: "Choose branches") {
            VStack(alignment: .leading, spacing: Layout.rowSpacing * 2) {
                BranchField(title: "Merge into", caption: "This branch receives the changes.",
                            selection: $flow.into, choices: flow.branchChoices, highlighted: flow.integrationBranches)
                HStack(spacing: Layout.fieldSpacing) {
                    Spacer().frame(width: Layout.fieldLabelWidth)
                    Button {
                        flow.swapBranches()
                    } label: {
                        Label("Swap", systemImage: Symbol.swap)
                    }
                    .buttonStyle(.borderless)
                    .help("Swap the two branches")
                }
                BranchField(title: "Merge from", caption: "Its changes are brought in.",
                            selection: $flow.from, choices: flow.branchChoices, highlighted: flow.integrationBranches)
            }
            .disabled(flow.step != .choose)
        }
    }

    // MARK: - Step 2: preview + Merge

    private var previewCard: some View {
        Card(number: 2, title: "What will happen") {
            VStack(alignment: .leading, spacing: Layout.rowSpacing * 2) {
                switch flow.preview {
                case .idle, .loading:
                    ProgressView("Checking…").controlSize(.small)
                case let .failed(message):
                    Label(message, systemImage: Symbol.warning).foregroundStyle(Palette.conflict)
                case let .loaded(preview):
                    previewLines(preview)
                }
                DisclosureGroup("Options") {
                    VStack(alignment: .leading) {
                        Picker("Merge as", selection: $flow.strategy) {
                            ForEach(MergeStrategy.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        Toggle("Get the latest changes from the server first (fetch)", isOn: $flow.fetchFirst)
                    }
                    .padding(.top, Layout.rowSpacing)
                }
                Button {
                    Task { await flow.merge() }
                } label: {
                    Text("Merge \(fromName) into \(intoName)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(flow.mergeBlockedReason != nil || flow.isBusy)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(AccessibilityID.mergeFlowButton)
                if let reason = flow.mergeBlockedReason, case .loaded = flow.preview {
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func previewLines(_ preview: MergePreview) -> some View {
        if preview.nothingToMerge {
            Label("\(intoName) already has everything from \(fromName). Nothing to merge.", systemImage: Symbol.clean)
                .foregroundStyle(Palette.clean)
        } else {
            let commits = preview.commitsToBring == 1 ? "1 commit" : "\(preview.commitsToBring) commits"
            Label("\(commits) from \(fromName) will be added to \(intoName).", systemImage: Symbol.merge)
            if let prediction = preview.prediction {
                if prediction.isClean {
                    Label("No conflicts expected.", systemImage: Symbol.clean).foregroundStyle(Palette.clean)
                } else {
                    let manual = prediction.manualCount
                    Label("\(prediction.conflicts.count) file\(prediction.conflicts.count == 1 ? "" : "s") will have conflicts"
                          + (prediction.automaticCount > 0 ? " — \(prediction.automaticCount) resolved automatically" : "")
                          + (manual > 0 ? ", \(manual) need\(manual == 1 ? "s" : "") you." : "."),
                          systemImage: Symbol.conflict)
                        .foregroundStyle(Palette.conflict)
                }
            }
            if preview.intoIsProtected {
                Label("\(intoName) is protected, so the result goes to a pull request for review.", systemImage: Symbol.info)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Step 3+: progress

    @ViewBuilder private var progressCard: some View {
        switch flow.step {
        case .choose:
            EmptyView()
        case .working:
            Card(number: 2, title: "Merging") {
                ProgressView("Merging \(fromName) into \(intoName)…").frame(maxWidth: .infinity, alignment: .leading)
            }
        case .resolveConflicts, .readyToComplete:
            conflictsCard
        case .readyToApply:
            Card(number: 3, title: "Merge is ready") {
                VStack(alignment: .leading, spacing: Layout.rowSpacing * 2) {
                    automaticSummary
                    Label("Everything merged. \(intoName) hasn't changed yet.", systemImage: Symbol.clean).foregroundStyle(Palette.clean)
                    HStack {
                        Button(flow.session?.viaPullRequest == true ? "Prepare Pull Request" : "Apply to \(intoName)") {
                            Task { await flow.apply() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier(AccessibilityID.mergeFlowApply)
                        Button("Discard Merge", role: .destructive) { Task { await flow.discard() } }
                            .controlSize(.large)
                    }
                    .disabled(flow.isBusy)
                }
            }
        case .applied:
            Card(number: 4, title: "Applied") {
                VStack(alignment: .leading, spacing: Layout.rowSpacing * 2) {
                    Label(flow.session?.viaPullRequest == true
                          ? "The merge is on the new branch \(flow.session?.pullRequestBranch ?? "") on this Mac."
                          : "\(intoName) now includes \(fromName) — on this Mac only.",
                          systemImage: Symbol.clean)
                        .foregroundStyle(Palette.clean)
                    HStack {
                        Button(flow.session?.viaPullRequest == true ? "Push & Open Pull Request…" : "Push to Server…") {
                            confirmPublish = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Button("Undo") { Task { await flow.undo() } }
                            .controlSize(.large)
                            .help("Put \(intoName) back exactly where it was")
                    }
                    .disabled(flow.isBusy)
                }
            }
        case .done:
            Card(number: 5, title: "Done") {
                VStack(alignment: .leading, spacing: Layout.rowSpacing * 2) {
                    Label(flow.session?.state == .pullRequestOpened ? "Pull request ready for review." : "\(intoName) is pushed.",
                          systemImage: Symbol.clean)
                        .foregroundStyle(Palette.clean)
                    if let url = flow.session?.pullRequestURL.flatMap(URL.init(string:)) {
                        Link("Open the pull request page", destination: url)
                    }
                    Button("Start a New Merge") { flow.startOver() }
                }
            }
        }
    }

    private var conflictsCard: some View {
        let remaining = flow.session?.conflictedFiles ?? []
        return Card(number: 3, title: remaining.isEmpty ? "All conflicts resolved" : "Resolve conflicts") {
            VStack(alignment: .leading, spacing: Layout.rowSpacing * 2) {
                automaticSummary
                if remaining.isEmpty {
                    Label("Every file is decided. Complete the merge to continue.", systemImage: Symbol.clean)
                        .foregroundStyle(Palette.clean)
                } else {
                    Text("\(remaining.count) file\(remaining.count == 1 ? " needs" : "s need") your decision.")
                        .font(.headline)
                    VStack(spacing: 0) {
                        ForEach(remaining, id: \.self) { path in
                            ConflictRow(path: path) { Task { await flow.openResolver(path) } }
                            Divider()
                        }
                    }
                }
                HStack {
                    Button("Complete Merge") { Task { await flow.complete() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!remaining.isEmpty || flow.isBusy)
                        .accessibilityIdentifier(AccessibilityID.mergeFlowComplete)
                    Button("Discard Merge", role: .destructive) { Task { await flow.discard() } }
                        .controlSize(.large)
                        .disabled(flow.isBusy)
                }
            }
        }
    }

    /// Files Merge Desk (or you) already resolved.
    @ViewBuilder private var automaticSummary: some View {
        let done = (flow.session?.resolutions ?? []).filter { $0.status == .applied }
        if !done.isEmpty {
            DisclosureGroup("\(done.count) file\(done.count == 1 ? "" : "s") already resolved") {
                VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                    ForEach(done) { resolution in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: Symbol.clean).foregroundStyle(Palette.clean)
                            Text(resolution.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text(resolution.tier == .manual ? "by you" : "automatically").font(.caption).foregroundStyle(.secondary)
                        }
                        .help(resolution.note)
                    }
                }
                .padding(.top, Layout.rowSpacing)
            }
        }
    }

    private var publishQuestion: String {
        flow.session?.viaPullRequest == true
            ? "Push the merge and open a pull request into \(intoName)?"
            : "Push \(intoName) to the server?"
    }
}

/// One conflicted file with its Resolve button.
private struct ConflictRow: View {
    let path: String
    let resolve: () -> Void

    var body: some View {
        HStack {
            Image(systemName: Symbol.document).foregroundStyle(Palette.conflict)
            VStack(alignment: .leading) {
                Text((path as NSString).lastPathComponent).fontWeight(.medium)
                Text((path as NSString).deletingLastPathComponent).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Button("Resolve…", action: resolve)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("\(AccessibilityID.resolveFilePrefix)\(path)")
        }
        .padding(.vertical, Layout.rowSpacing * 2)
    }
}

/// A labelled branch picker with a one-line explanation.
private struct BranchField: View {
    let title: String
    let caption: String
    @Binding var selection: String?
    let choices: [String]
    let highlighted: Set<String>

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.fieldSpacing) {
            Text(title).font(.headline).frame(width: Layout.fieldLabelWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                Picker(title, selection: $selection) {
                    Text("Choose a branch…").tag(String?.none)
                    Divider()
                    ForEach(choices, id: \.self) { name in
                        Text(highlighted.contains(name) ? "\(name)  (main line)" : name).tag(String?.some(name))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: Layout.branchPickerWidth, alignment: .leading)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A numbered step card.
struct Card<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing * 3) {
            HStack(spacing: Layout.rowSpacing * 2) {
                Text("\(number)")
                    .font(.headline)
                    .frame(width: Layout.stepBadgeSize, height: Layout.stepBadgeSize)
                    .background(Color.accentColor.opacity(Layout.badgeBackgroundOpacity), in: Circle())
                Text(title).font(.title3.bold())
            }
            content()
        }
        .padding(Layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Layout.cardCornerRadius))
    }
}

/// Detail column for the Merge tab: how it works, in five lines.
struct MergeHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                Text("How it works").font(.title2.bold())
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(index + 1).").bold().monospacedDigit()
                        Text(step)
                    }
                }
                Divider()
                Label("Your checkout and uncommitted work are never touched.", systemImage: Symbol.clean)
                Label("Undo puts the branch back exactly, until you push.", systemImage: Symbol.clean)
                Label("Protected branches only change through a pull request.", systemImage: Symbol.clean)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let steps = [
        "Choose the branch to merge into, and the branch to merge from.",
        "Check what will happen, then press Merge.",
        "If files conflict, press Resolve on each and pick which version to keep.",
        "Press Complete Merge, then Apply.",
        "Push when you're ready (or open a pull request for protected branches).",
    ]
}
