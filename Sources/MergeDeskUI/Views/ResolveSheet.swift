import AppKit
import MergeDeskCore
import SwiftUI

/// Resolve one file: for each conflict, keep one branch's lines or both — shown side by side under the branch
/// names. Files deleted on one side, or binary files, get a simple whole-file choice.
struct ResolveSheet: View {
    @Bindable var flow: MergeFlowModel
    @Environment(\.dismiss) private var dismiss

    private var intoName: String { flow.session?.target ?? "into" }
    private var fromName: String { flow.session?.source ?? "from" }
    private var path: String { flow.resolvingPath ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: Layout.resolveSheetWidth, minHeight: Layout.resolveSheetHeight)
        .accessibilityIdentifier(AccessibilityID.resolveSheet)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            Text((path as NSString).lastPathComponent).font(.title2.bold())
            Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if case let .loaded(.text(text)) = flow.fileConflict {
                Text("\(text.conflictCount) place\(text.conflictCount == 1 ? "" : "s") changed differently on both branches. "
                     + "For each, choose what to keep.")
                HStack {
                    Text("For all:").foregroundStyle(.secondary)
                    Button("Keep \(intoName)") { flow.chooseForAll(.into) }
                    Button("Keep \(fromName)") { flow.chooseForAll(.from) }
                    Button("Keep both") { flow.chooseForAll(.both) }
                }
                .controlSize(.small)
            }
        }
        .padding()
    }

    @ViewBuilder private var content: some View {
        switch flow.fileConflict {
        case .idle, .loading:
            ProgressView("Reading the file…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            Label(message, systemImage: Symbol.warning).foregroundStyle(Palette.conflict).padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(.text(text)):
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    ForEach(text.blocks) { block in
                        BlockCard(block: block, total: text.conflictCount, intoName: intoName, fromName: fromName,
                                  choice: Binding(
                                    get: { flow.choices.indices.contains(block.id) ? flow.choices[block.id] : nil },
                                    set: { if flow.choices.indices.contains(block.id) { flow.choices[block.id] = $0 } }))
                    }
                    if let preview = flow.resolvedPreview {
                        DisclosureGroup("Preview the saved file") {
                            ScrollView(.horizontal) {
                                Text(preview).font(.caption.monospaced()).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: Layout.previewMaxHeight)
                        }
                    }
                }
                .padding()
            }
        case let .loaded(.presentOnOneSide(inInto, _)):
            WholeFileChoice(
                message: inInto
                    ? "\(fromName) deleted this file, but \(intoName) still has it (and may have changed it)."
                    : "\(intoName) deleted this file, but \(fromName) still has it (and may have changed it).",
                keepTitle: "Keep the file",
                keep: { Task { await flow.keepWholeFile(inInto ? .into : .from) } },
                deleteTitle: "Delete the file",
                delete: { Task { await flow.keepWholeFile(inInto ? .from : .into) } })
        case .loaded(.binary):
            WholeFileChoice(
                message: "This is a binary file (an image or similar), so it can't be merged line by line. Pick one version.",
                keepTitle: "Use \(intoName)'s version",
                keep: { Task { await flow.keepWholeFile(.into) } },
                deleteTitle: "Use \(fromName)'s version",
                delete: { Task { await flow.keepWholeFile(.from) } })
        }
    }

    private var footer: some View {
        HStack {
            if let worktree = flow.session?.worktreePath {
                Button("Open in Editor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: worktree).appendingPathComponent(path))
                }
                .help("For complex cases: edit the file in your editor and remove the <<<<<<< / >>>>>>> markers")
                Button("I've Edited It — Mark Resolved") { Task { await flow.markEditedResolved() } }
                    .help("Use the file as you saved it in your editor")
            }
            if let error = flow.errorMessage, flow.resolvingPath != nil {
                Text(error).font(.caption).foregroundStyle(Palette.conflict).lineLimit(2)
            }
            Spacer()
            if case .loaded(.text) = flow.fileConflict {
                Text("\(flow.choices.compactMap { $0 }.count) of \(flow.choices.count) decided").foregroundStyle(.secondary)
            }
            Button("Cancel") { flow.closeResolver() }
                .keyboardShortcut(.cancelAction)
            if case .loaded(.text) = flow.fileConflict {
                Button("Save Resolution") { Task { await flow.saveChoices() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.canSaveChoices || flow.isBusy)
                    .accessibilityIdentifier(AccessibilityID.saveResolution)
            }
        }
        .padding()
    }
}

/// One conflict: the two versions side by side and the three choices.
private struct BlockCard: View {
    let block: ConflictBlock
    let total: Int
    let intoName: String
    let fromName: String
    @Binding var choice: BlockChoice?

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing * 2) {
            HStack {
                Text("Conflict \(block.id + 1) of \(total)").font(.headline)
                Spacer()
                if choice != nil { Image(systemName: Symbol.clean).foregroundStyle(Palette.clean) }
            }
            if !block.before.isEmpty { ContextLines(lines: block.before) }
            HStack(alignment: .top, spacing: Layout.rowSpacing * 2) {
                VersionBox(title: "\(intoName)", subtitle: "merge into", lines: block.into,
                           isChosen: choice == .into || choice == .both) { choice = .into }
                VersionBox(title: "\(fromName)", subtitle: "merge from", lines: block.from,
                           isChosen: choice == .from || choice == .both) { choice = .from }
            }
            if !block.after.isEmpty { ContextLines(lines: block.after) }
            Picker("Keep", selection: $choice) {
                Text("Keep \(intoName)").tag(BlockChoice?.some(.into))
                Text("Keep \(fromName)").tag(BlockChoice?.some(.from))
                Text("Keep both").tag(BlockChoice?.some(.both))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(Layout.cardPadding)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Layout.cardCornerRadius))
    }
}

/// One branch's lines for a conflict; clicking it chooses that version.
private struct VersionBox: View {
    let title: String
    let subtitle: String
    let lines: [String]
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.rowSpacing) {
            HStack {
                Text(title).font(.subheadline.bold()).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                Text(lines.isEmpty ? "(nothing — these lines were removed)" : lines.joined(separator: "\n"))
                    .font(.callout.monospaced())
                    .foregroundStyle(lines.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Layout.rowSpacing * 2)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Layout.badgeCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Layout.badgeCornerRadius)
            .stroke(isChosen ? Color.accentColor : Color.secondary.opacity(Layout.matrixLightOpacity), lineWidth: isChosen ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .help("Click to keep this version")
    }
}

private struct ContextLines: View {
    let lines: [String]

    var body: some View {
        Text(lines.joined(separator: "\n"))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(Layout.contextLineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WholeFileChoice: View {
    let message: String
    let keepTitle: String
    let keep: () -> Void
    let deleteTitle: String
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            Text(message)
            HStack {
                Button(keepTitle, action: keep).buttonStyle(.borderedProminent).controlSize(.large)
                Button(deleteTitle, action: delete).controlSize(.large)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
