import MergeDeskCore
import SwiftUI

/// Heat map of active branches that conflict with each other. Rows are named; columns use the row numbers so
/// the grid stays compact. Click a cell to see the files.
struct MatrixView: View {
    @Bindable var model: RepositoryModel

    var body: some View {
        switch model.matrixState {
        case .idle, .loading:
            ProgressView("Predicting merges between active branches…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't predict the matrix", systemImage: Symbol.warning)
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.loadMatrix() }
            }
        case let .loaded(report):
            if let matrix = report.matrix, matrix.branches.count > 1 {
                content(matrix)
            } else {
                ContentUnavailableView("Not enough active branches", systemImage: Symbol.merge,
                                       description: Text("The matrix compares recent, unmerged branches with each other."))
            }
        }
    }

    private func content(_ matrix: MatrixPredictions) -> some View {
        VSplitView {
            ScrollView([.horizontal, .vertical]) {
                grid(matrix)
                    .padding()
            }
            .frame(minHeight: Layout.matrixCellSize * 4)
            .accessibilityIdentifier(AccessibilityID.matrix)
            pairDetail(matrix)
        }
    }

    private func grid(_ matrix: MatrixPredictions) -> some View {
        let names = matrix.branches
        return Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                Text("\(matrix.conflictingPairs.count) conflicting pairs among \(names.count) active branches")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: Layout.matrixLabelWidth + Layout.matrixNumberWidth, alignment: .leading)
                    .gridCellColumns(2)
                ForEach(names.indices, id: \.self) { column in
                    Text("\(column + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: Layout.matrixCellSize)
                }
            }
            ForEach(Array(names.enumerated()), id: \.offset) { row, name in
                GridRow {
                    Text(name).lineLimit(1).truncationMode(.middle).font(.callout)
                        .frame(width: Layout.matrixLabelWidth, alignment: .trailing)
                        .help(name)
                    Text("\(row + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: Layout.matrixNumberWidth)
                    ForEach(Array(names.enumerated()), id: \.offset) { column, other in
                        cell(row == column ? nil : matrix.pair(name, other), isDiagonal: row == column, rowName: name, columnName: other)
                    }
                }
            }
        }
    }

    private func cell(_ pair: PairPrediction?, isDiagonal: Bool, rowName: String, columnName: String) -> some View {
        let count = pair?.prediction.conflicts.count ?? 0
        let isSelected = pair != nil && pair?.id == model.selectedPair?.id
        return RoundedRectangle(cornerRadius: Layout.matrixCornerRadius)
            .fill(isDiagonal ? Palette.matrixDiagonal : Self.color(for: count))
            .overlay {
                if count > 0 { Text("\(count)").font(.caption2.monospacedDigit().bold()) }
            }
            .overlay {
                if isSelected { RoundedRectangle(cornerRadius: Layout.matrixCornerRadius).stroke(Color.accentColor, lineWidth: 2) }
            }
            .frame(width: Layout.matrixCellSize, height: Layout.matrixCellSize)
            .help(isDiagonal ? rowName : "\(rowName) ↔ \(columnName): \(count == 0 ? "clean" : "\(count) conflicting files")")
            .onTapGesture { if let pair { model.selectedPair = pair } }
            .accessibilityLabel(isDiagonal ? rowName : "\(rowName) and \(columnName), \(count) conflicts")
    }

    static func color(for count: Int) -> Color {
        switch count {
        case 0: return Palette.matrixEmpty
        case ..<Layout.matrixMediumThreshold: return Palette.conflict.opacity(Layout.matrixLightOpacity)
        case ..<Layout.matrixStrongThreshold: return Palette.conflict.opacity(Layout.matrixMediumOpacity)
        default: return Color.red.opacity(Layout.matrixStrongOpacity)
        }
    }

    @ViewBuilder private func pairDetail(_ matrix: MatrixPredictions) -> some View {
        if let pair = model.selectedPair, matrix.pair(pair.first, pair.second) != nil {
            ConflictList(title: "\(pair.first) ↔ \(pair.second) — \(pair.prediction.summary)",
                         conflicts: pair.prediction.conflicts)
                .accessibilityIdentifier(AccessibilityID.matrixPair)
        } else {
            Text(matrix.omittedBranches.isEmpty
                 ? "Click a coloured cell to see the files both branches change."
                 : "Click a coloured cell to see the files. \(matrix.omittedBranches.count) older active branches are left out "
                    + "(limit \(Predictor.maxMatrixBranches)).")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: Layout.matrixCellSize * 3)
        }
    }
}

/// A list of predicted conflicting files with how each would be resolved.
struct ConflictList: View {
    let title: String
    let conflicts: [PredictedConflict]

    var body: some View {
        List {
            Section(title) {
                ForEach(conflicts) { conflict in
                    HStack {
                        Text(conflict.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.head).help(conflict.path)
                        Spacer()
                        Text(conflict.kinds.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        RouteBadge(route: conflict.route)
                    }
                }
            }
        }
    }
}

/// How a predicted conflict would be resolved: green for an automatic rule, orange for a person.
struct RouteBadge: View {
    let route: ResolutionRoute

    var body: some View {
        Text(route.label)
            .font(.caption)
            .padding(.horizontal, Layout.badgeHorizontalPadding)
            .padding(.vertical, Layout.badgeVerticalPadding)
            .background((route.isAutomatic ? Palette.clean : Palette.conflict).opacity(Layout.badgeBackgroundOpacity),
                        in: RoundedRectangle(cornerRadius: Layout.badgeCornerRadius))
            .foregroundStyle(route.isAutomatic ? Palette.clean : Palette.conflict)
            .help(route.isAutomatic ? "A file rule resolves this automatically" : "Needs the history engine or a person")
    }
}
