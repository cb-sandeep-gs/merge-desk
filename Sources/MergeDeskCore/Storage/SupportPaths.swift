import CryptoKit
import Foundation

/// Where Merge Desk keeps per-repository state (sessions, audit log, digests). Never inside the repository
/// itself, so nothing Merge Desk writes can be committed or bundled by accident.
public struct SupportPaths: Sendable, Equatable {
    public let root: URL

    /// Environment variable that points Merge Desk at another support folder.
    public static let rootOverrideVariable = "MERGEDESK_SUPPORT_DIR"

    /// - Parameter root: base folder; defaults to `~/Library/Application Support/MergeDesk`. Tests pass a temp dir.
    public init(root: URL? = nil, fileManager: FileManager = .default) {
        if let root {
            self.root = root
        } else if let override = ProcessInfo.processInfo.environment[Self.rootOverrideVariable], !override.isEmpty {
            // Demos, screenshots and manual testing without touching the real support folder.
            self.root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.root = base.appendingPathComponent(MergeDeskConstants.applicationSupportFolderName, isDirectory: true)
        }
    }

    /// Stable, readable folder name for a repository: `<folder-name>-<hash of the absolute path>`.
    /// The hash keeps two clones with the same folder name apart.
    public static func repositoryIdentifier(for repositoryRoot: URL) -> String {
        let path = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(MergeDeskConstants.repositoryIdentifierHashLength)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let name = String(repositoryRoot.lastPathComponent.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return "\(name)-\(hash)"
    }

    public func repositoryFolder(for repositoryRoot: URL) -> URL {
        root.appendingPathComponent(RepositoryFolder.repositories, isDirectory: true)
            .appendingPathComponent(Self.repositoryIdentifier(for: repositoryRoot), isDirectory: true)
    }

    public func auditLog(for repositoryRoot: URL) -> URL {
        repositoryFolder(for: repositoryRoot).appendingPathComponent(MergeDeskConstants.auditLogFileName)
    }

    private enum RepositoryFolder {
        static let repositories = "repos"
    }
}
