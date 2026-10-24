import Foundation

/// Merge outcomes keyed by commit ids, kept in memory and on disk in the repository's support folder.
/// Commit ids never change meaning, so an entry is valid forever; the store only drops the least recently used
/// entries to stay small.
public actor PredictionStore {
    public static let fileName = "prediction-cache.json"
    /// Enough for every integration pair plus a full 40-branch matrix several times over.
    public static let maxEntries = 5_000

    /// Order-independent for branch × branch pairs (a merge's conflicts are the same both ways); ordered for
    /// branch-into-integration pairs is unnecessary for the same reason, so every key is the sorted id pair.
    struct Key: Hashable, Codable {
        let low: String
        let high: String

        init(_ first: String, _ second: String) {
            (low, high) = first < second ? (first, second) : (second, first)
        }
    }

    private struct Entry: Codable {
        let key: Key
        let outcome: MergeOutcome
        var lastUsed: Date
    }

    public let fileURL: URL?
    private var entries: [Key: Entry] = [:]
    private var isLoaded = false
    private var isDirty = false

    /// - Parameter fileURL: where to persist; nil keeps the cache in memory only (tests, one-off runs).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    public init(paths: SupportPaths, repositoryRoot: URL) {
        self.init(fileURL: paths.repositoryFolder(for: repositoryRoot).appendingPathComponent(Self.fileName))
    }

    public var count: Int {
        loadIfNeeded()
        return entries.count
    }

    func outcome(_ first: String, _ second: String, now: Date) -> MergeOutcome? {
        loadIfNeeded()
        let key = Key(first, second)
        guard var entry = entries[key] else { return nil }
        entry.lastUsed = now
        entries[key] = entry
        isDirty = true
        return entry.outcome
    }

    func store(_ outcome: MergeOutcome, _ first: String, _ second: String, now: Date) {
        loadIfNeeded()
        let key = Key(first, second)
        entries[key] = Entry(key: key, outcome: outcome, lastUsed: now)
        isDirty = true
    }

    /// Writes the cache if it changed, keeping the `maxEntries` most recently used entries.
    public func save() throws {
        guard isDirty, let fileURL else { return }
        if entries.count > Self.maxEntries {
            let keep = entries.values.sorted { $0.lastUsed > $1.lastUsed }.prefix(Self.maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0) })
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(Array(entries.values)).write(to: fileURL, options: .atomic)
        isDirty = false
    }

    /// A missing or unreadable cache file is simply an empty cache (it only saves time).
    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let saved = try? decoder.decode([Entry].self, from: data) else { return }
        entries = Dictionary(saved.map { ($0.key, $0) }, uniquingKeysWith: { lhs, rhs in lhs.lastUsed > rhs.lastUsed ? lhs : rhs })
    }
}
