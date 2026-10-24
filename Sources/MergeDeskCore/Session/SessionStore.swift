import Foundation

/// Sessions as one JSON file each under the repository's support folder (`sessions/<uuid>.json`).
public struct SessionStore: Sendable {
    static let folderName = "sessions"
    static let fileExtension = "json"

    public let folder: URL

    public init(paths: SupportPaths = SupportPaths(), repositoryRoot: URL) {
        folder = paths.repositoryFolder(for: repositoryRoot).appendingPathComponent(Self.folderName, isDirectory: true)
    }

    public func save(_ session: MergeSession) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder.encode(session).write(to: url(for: session.id), options: .atomic)
    }

    public func load(_ id: UUID) throws -> MergeSession {
        try Self.decoder.decode(MergeSession.self, from: Data(contentsOf: url(for: id)))
    }

    /// All sessions, newest first. Unreadable files are skipped (they never block the list).
    public func all() -> [MergeSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == Self.fileExtension }
            .compactMap { try? Self.decoder.decode(MergeSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Finds a session by full UUID or by the short id shown in the CLI.
    public func find(_ idOrPrefix: String) -> MergeSession? {
        let needle = idOrPrefix.lowercased()
        let matches = all().filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
        return matches.count == 1 ? matches.first : nil
    }

    private func url(for id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension(Self.fileExtension)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
