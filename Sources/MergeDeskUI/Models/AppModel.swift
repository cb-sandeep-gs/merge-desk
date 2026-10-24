import Foundation
import MergeDeskCore
import Observation

/// App-wide state: the repositories sidebar and the model of the selected repository.
@MainActor
@Observable
public final class AppModel {
    public private(set) var repositories: [RegisteredRepository] = []
    public var selectedRepositoryID: RegisteredRepository.ID? {
        didSet {
            guard selectedRepositoryID != oldValue else { return }
            // First visit loads; later visits keep the loaded inventory (Refresh updates it).
            if let model = selectedModel, model.inventoryState.value == nil, !model.inventoryState.isLoading {
                model.refresh()
            }
        }
    }
    /// Latest add/remove problem, shown as an alert.
    public var alertMessage: String?

    private let registry: RepositoryRegistry
    private let git: GitClient
    /// One model per repository, so switching back keeps filters, sort and selection.
    private var models: [RegisteredRepository.ID: RepositoryModel] = [:]

    public init(registry: RepositoryRegistry = RepositoryRegistry(), git: GitClient = ProcessGitClient()) {
        self.registry = registry
        self.git = git
        do {
            repositories = try registry.load()
        } catch {
            alertMessage = "Couldn't read the saved repositories: \(ErrorText.message(error))"
        }
        selectedRepositoryID = repositories.first?.id
    }

    public var selectedModel: RepositoryModel? {
        guard let id = selectedRepositoryID, let repository = repositories.first(where: { $0.id == id }) else { return nil }
        return model(for: repository)
    }

    public func model(for repository: RegisteredRepository) -> RepositoryModel {
        if let existing = models[repository.id] { return existing }
        let model = RepositoryModel(repository: repository, git: git)
        models[repository.id] = model
        return model
    }

    /// Adds the repository containing `folder` and selects it.
    public func addRepository(at folder: URL) async {
        do {
            let (repository, updated) = try await registry.add(folder: folder, to: repositories)
            repositories = updated
            selectedRepositoryID = repository.id
        } catch {
            alertMessage = ErrorText.message(error)
        }
    }

    /// Removes a repository from Merge Desk (the folder itself is untouched).
    public func removeRepository(_ id: RegisteredRepository.ID) {
        do {
            repositories = try registry.remove(id: id, from: repositories)
            models[id] = nil
            if selectedRepositoryID == id { selectedRepositoryID = repositories.first?.id }
        } catch {
            alertMessage = ErrorText.message(error)
        }
    }
}
