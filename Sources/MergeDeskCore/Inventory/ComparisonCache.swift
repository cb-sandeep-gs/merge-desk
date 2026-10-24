import Foundation

/// Results keyed by commit ids, so they never go stale: a branch that moved has a new id and simply misses.
/// Shared by inventory refreshes and branch details within one app session.
public actor ComparisonCache {
    /// Ordered pair of commit ids (`tip` compared with `base`).
    public struct Key: Hashable, Sendable {
        public let tip: String
        public let base: String
    }

    private var aheadBehind: [Key: AheadBehind] = [:]
    private var changedFiles: [Key: [String]] = [:]

    public init() {}

    public func aheadBehind(tip: String, base: String) -> AheadBehind? {
        aheadBehind[Key(tip: tip, base: base)]
    }

    public func store(_ value: AheadBehind, tip: String, base: String) {
        aheadBehind[Key(tip: tip, base: base)] = value
    }

    public func changedFiles(tip: String, base: String) -> [String]? {
        changedFiles[Key(tip: tip, base: base)]
    }

    public func store(changedFiles value: [String], tip: String, base: String) {
        changedFiles[Key(tip: tip, base: base)] = value
    }
}
