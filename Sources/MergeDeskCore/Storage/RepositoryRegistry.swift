import Foundation

/// A repository the user added to Merge Desk.
public struct RegisteredRepository: Sendable, Equatable, Codable, Identifiable, Hashable {
    public let id: UUID
    /// Top-level folder of the repository (resolved through git, so it is the root even if a subfolder was picked).
    public let path: String
    public let addedAt: Date

    public init(id: UUID = UUID(), path: String, addedAt: Date = Date()) {
        self.id = id
        self.path = path
        // Whole seconds: the registry file stores ISO-8601, so a reloaded entry must equal the one in memory.
        self.addedAt = Date(timeIntervalSince1970: addedAt.timeIntervalSince1970.rounded(.down))
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    public var displayName: String { url.lastPathComponent }
}

public enum RepositoryRegistryError: Error, Equatable, CustomStringConvertible {
    case notARepository(String)
    case alreadyAdded(String)

    public var description: String {
        switch self {
        case let .notARepository(path): return "\(path) is not inside a git repository."
        case let .alreadyAdded(path): return "\(path) is already in Merge Desk."
        }
    }
}

/// The list of added repositories, stored as JSON in the support folder (never in a repository).
public struct RepositoryRegistry: Sendable {
    public static let fileName = "repositories.json"

    public let fileURL: URL
    private let git: GitClient

    public init(paths: SupportPaths = SupportPaths(), git: GitClient = ProcessGitClient()) {
        self.fileURL = paths.root.appendingPathComponent(Self.fileName)
        self.git = git
    }

    /// Saved repositories in the order they were added; a missing file is an empty list.
    public func load() throws -> [RegisteredRepository] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([RegisteredRepository].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ repositories: [RegisteredRepository]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(repositories).write(to: fileURL, options: .atomic)
    }

    /// Resolves `folder` to its repository root and appends it. Returns the new list.
    public func add(folder: URL, to repositories: [RegisteredRepository]) async throws -> (RegisteredRepository, [RegisteredRepository]) {
        let root: URL
        do {
            root = try await git.execute(.repositoryRoot, in: folder)
        } catch {
            throw RepositoryRegistryError.notARepository(folder.path)
        }
        let path = root.standardizedFileURL.path
        guard !repositories.contains(where: { $0.path == path }) else { throw RepositoryRegistryError.alreadyAdded(path) }
        let repository = RegisteredRepository(path: path)
        let updated = repositories + [repository]
        try save(updated)
        return (repository, updated)
    }

    public func remove(id: UUID, from repositories: [RegisteredRepository]) throws -> [RegisteredRepository] {
        let updated = repositories.filter { $0.id != id }
        try save(updated)
        return updated
    }
}
