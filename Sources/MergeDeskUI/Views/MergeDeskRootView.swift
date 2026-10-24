import AppKit
import MergeDeskCore
import SwiftUI
import UniformTypeIdentifiers

/// The main window: repositories | branches | branch detail.
public struct MergeDeskRootView: View {
    @Bindable private var app: AppModel
    @State private var isPickingFolder = false

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        NavigationSplitView {
            RepositorySidebar(app: app, isPickingFolder: $isPickingFolder)
                .navigationSplitViewColumnWidth(min: Layout.sidebarMinWidth, ideal: Layout.sidebarIdealWidth)
        } content: {
            if let model = app.selectedModel {
                BranchesView(model: model)
                    .navigationSplitViewColumnWidth(min: Layout.tableMinWidth, ideal: Layout.tableIdealWidth)
            } else {
                ContentUnavailableView {
                    Label("No repository", systemImage: Symbol.repository)
                } description: {
                    Text("Add a git repository to see its branches.")
                } actions: {
                    Button("Add Repository…") { isPickingFolder = true }
                }
            }
        } detail: {
            if let model = app.selectedModel, model.contentMode == .merge {
                MergeHelpView()
                    .navigationSplitViewColumnWidth(min: Layout.detailMinWidth, ideal: Layout.detailIdealWidth, max: Layout.detailMaxWidth)
            } else if let model = app.selectedModel, model.contentMode == .merges {
                SessionDetailView(sessions: model.sessions)
                    .navigationSplitViewColumnWidth(min: Layout.detailMinWidth, ideal: Layout.detailIdealWidth, max: Layout.detailMaxWidth)
            } else if let model = app.selectedModel {
                BranchDetailView(model: model)
                    .navigationSplitViewColumnWidth(min: Layout.detailMinWidth, ideal: Layout.detailIdealWidth, max: Layout.detailMaxWidth)
            } else {
                Color.clear
            }
        }
        // Ideal = first-launch size; without it the window opens at its minimum and hides the right-hand columns.
        .frame(minWidth: Layout.windowMinWidth, idealWidth: Layout.windowDefaultWidth,
               minHeight: Layout.windowMinHeight, idealHeight: Layout.windowDefaultHeight)
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }
            Task { await app.addRepository(at: url) }
        }
        .alert("Merge Desk", isPresented: Binding(
            get: { app.alertMessage != nil },
            set: { if !$0 { app.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.alertMessage ?? "")
        }
    }
}

/// Repositories the user added, with add / reveal / remove.
struct RepositorySidebar: View {
    @Bindable var app: AppModel
    @Binding var isPickingFolder: Bool

    var body: some View {
        List(selection: $app.selectedRepositoryID) {
            Section("Repositories") {
                ForEach(app.repositories) { repository in
                    Label(repository.displayName, systemImage: Symbol.repository)
                        .help(repository.path)
                        .tag(repository.id)
                        .contextMenu {
                            Button("Reveal in Finder", systemImage: Symbol.revealInFinder) {
                                NSWorkspace.shared.activateFileViewerSelecting([repository.url])
                            }
                            Divider()
                            Button("Remove from Merge Desk", systemImage: Symbol.remove, role: .destructive) {
                                app.removeRepository(repository.id)
                            }
                        }
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.repositoryList)
        .overlay {
            if app.repositories.isEmpty {
                Text("No repositories yet").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Add Repository…", systemImage: Symbol.add) { isPickingFolder = true }
                    .help("Add a git repository (the folder is never modified)")
                    .accessibilityIdentifier(AccessibilityID.addRepository)
            }
        }
    }
}
