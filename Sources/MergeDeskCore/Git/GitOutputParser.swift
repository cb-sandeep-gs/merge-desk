import Foundation

/// Pure parsers for machine-readable git output. No I/O, so every edge case is unit-testable from bytes.
public enum GitOutputParser {
    private static let nul = UInt8(ascii: "\0")
    private static let newline = UInt8(ascii: "\n")

    // MARK: - for-each-ref

    /// Fields are NUL-separated, one ref per line (ref names and author fields can't contain NUL or newline).
    /// Order must match `parseRefs`.
    static let refFormat = [
        "%(refname)", "%(objectname)", "%(committerdate:unix)", "%(authorname)", "%(authoremail)",
        "%(upstream)", "%(symref)",
    ].joined(separator: "%00")
    private static let refFieldCount = 7

    public static func parseRefs(_ data: Data) throws -> [GitRef] {
        try data.split(separator: newline, omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: nul, omittingEmptySubsequences: false).map { decode($0) }
            guard fields.count == refFieldCount else {
                throw GitError.unexpectedOutput(query: "for-each-ref", detail: "expected \(refFieldCount) fields, got \(fields.count)")
            }
            let (fullName, objectID, dateText, author, email, upstream, symref) =
                (fields[0], fields[1], fields[2], fields[3], fields[4], fields[5], fields[6])
            // Symbolic refs such as refs/remotes/origin/HEAD point at another branch; listing them would duplicate it.
            guard symref.isEmpty else { return nil }
            guard let kind = refKind(fullName), let seconds = TimeInterval(dateText) else {
                throw GitError.unexpectedOutput(query: "for-each-ref", detail: "unrecognised ref line for \(fullName)")
            }
            return GitRef(
                fullName: fullName,
                kind: kind.kind,
                branchName: kind.branchName,
                objectID: objectID,
                committerDate: Date(timeIntervalSince1970: seconds),
                authorName: author,
                authorEmail: email.trimmingCharacters(in: CharacterSet(charactersIn: "<>")),
                upstream: upstream.isEmpty ? nil : upstream
            )
        }
    }

    /// Splits a full ref into its kind and branch name. Remote names are taken as the first path component.
    static func refKind(_ fullName: String) -> (kind: GitRef.Kind, branchName: String)? {
        let localPrefix = RefNamespace.localBranches + "/"
        let remotePrefix = RefNamespace.remoteBranches + "/"
        if fullName.hasPrefix(localPrefix) {
            return (.local, String(fullName.dropFirst(localPrefix.count)))
        }
        if fullName.hasPrefix(remotePrefix) {
            let rest = fullName.dropFirst(remotePrefix.count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            return (.remote(name: String(rest[..<slash])), String(rest[rest.index(after: slash)...]))
        }
        return nil
    }

    // MARK: - rev-list --left-right --count

    /// `"<left>\t<right>\n"` for `base...branch`: left = only on base (behind), right = only on branch (ahead).
    public static func parseLeftRightCount(_ data: Data) throws -> AheadBehind {
        let parts = trimmedLine(data).split(whereSeparator: { $0 == "\t" || $0 == " " })
        guard parts.count == 2, let behind = Int(parts[0]), let ahead = Int(parts[1]) else {
            throw GitError.unexpectedOutput(query: "rev-list --left-right --count", detail: trimmedLine(data))
        }
        return AheadBehind(ahead: ahead, behind: behind)
    }

    // MARK: - merge-tree --write-tree --name-only -z

    /// Layout: `<tree>NUL` then, when conflicted, `<path>NUL…` `NUL` and messages as
    /// `<count>NUL<path>NUL…<type>NUL<text>NUL`. Exit 1 with empty stdout is an error (e.g. unknown ref),
    /// not a conflict — git uses the same code for both.
    public static func parseMergeTree(_ result: GitResult) throws -> MergeTreeResult {
        let query = "merge-tree"
        guard !result.standardOutput.isEmpty else {
            throw GitError.commandFailed(arguments: result.arguments, exitCode: result.exitCode, message: result.errorText)
        }
        var fields = ArraySlice(result.standardOutput.split(separator: nul, omittingEmptySubsequences: false).map { decode($0) })
        // The output ends with NUL, which leaves one empty trailing field.
        if fields.last == "" { fields.removeLast() }
        guard let treeID = fields.popFirst(), isObjectID(treeID) else {
            throw GitError.unexpectedOutput(query: query, detail: "missing tree id")
        }
        guard result.exitCode == GitExitCode.one else {
            return MergeTreeResult(treeID: treeID, conflictedPaths: [], messages: [])
        }

        var conflicted: [String] = []
        while let field = fields.popFirst(), !field.isEmpty {
            conflicted.append(field)
        }
        var messages: [MergeTreeResult.Message] = []
        while let countText = fields.popFirst() {
            guard let count = Int(countText), count >= 0, fields.count >= count + 2 else {
                throw GitError.unexpectedOutput(query: query, detail: "malformed message block near '\(countText)'")
            }
            let paths = Array(fields.prefix(count))
            fields.removeFirst(count)
            let type = fields.removeFirst()
            let text = fields.removeFirst().trimmingCharacters(in: .newlines)
            messages.append(.init(paths: paths, type: type, text: text))
        }
        // Unique, in git's order: a path can be listed once per conflicting stage in some git versions.
        var seen = Set<String>()
        let uniquePaths = conflicted.filter { seen.insert($0).inserted }
        return MergeTreeResult(treeID: treeID, conflictedPaths: uniquePaths, messages: messages)
    }

    // MARK: - status --porcelain=v2 --branch -z

    private enum StatusPrefix {
        static let header = "# "
        static let changed = "1 "
        static let renamed = "2 "
        static let unmerged = "u "
        static let untracked = "? "
        static let ignored = "! "
    }

    private enum StatusHeader {
        static let objectID = "branch.oid"
        static let head = "branch.head"
        static let upstream = "branch.upstream"
        static let aheadBehind = "branch.ab"
        static let detached = "(detached)"
        static let initial = "(initial)"
    }

    /// Space-separated fields before the path, per record type (see `git status` "Porcelain Format Version 2").
    private enum StatusFieldCount {
        static let changed = 8
        static let renamed = 9
        static let unmerged = 10
    }

    public static func parseStatus(_ data: Data) throws -> WorkingTreeStatus {
        var records = ArraySlice(data.split(separator: nul, omittingEmptySubsequences: true).map { decode($0) })
        var headers = StatusHeaders()
        var entries: [WorkingTreeStatus.Entry] = []

        while let record = records.popFirst() {
            if record.hasPrefix(StatusPrefix.header) {
                headers.apply(String(record.dropFirst(StatusPrefix.header.count)))
            } else if record.hasPrefix(StatusPrefix.renamed) {
                // A rename's original path is the next NUL-separated record.
                guard let original = records.popFirst() else {
                    throw GitError.unexpectedOutput(query: "status", detail: "rename without original path")
                }
                let base = try entry(record, kind: .renamedOrCopied, fieldCount: StatusFieldCount.renamed)
                entries.append(.init(kind: base.kind, state: base.state, path: base.path, originalPath: original))
            } else {
                entries.append(try singleRecordEntry(record))
            }
        }
        return WorkingTreeStatus(
            branch: headers.branch, headObjectID: headers.headObjectID, upstream: headers.upstream,
            ahead: headers.ahead, behind: headers.behind, entries: entries
        )
    }

    /// `# branch.*` header values collected while walking the records.
    private struct StatusHeaders {
        var branch: String?
        var headObjectID: String?
        var upstream: String?
        var ahead: Int?
        var behind: Int?

        /// `text` is a header without its `# ` prefix, e.g. `branch.ab +2 -7`.
        mutating func apply(_ text: String) {
            let parts = text.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return }
            let value = String(parts[1])
            switch parts[0] {
            case StatusHeader.objectID: headObjectID = value == StatusHeader.initial ? nil : value
            case StatusHeader.head: branch = value == StatusHeader.detached ? nil : value
            case StatusHeader.upstream: upstream = value
            case StatusHeader.aheadBehind:
                // "+<ahead> -<behind>": drop the sign characters.
                let counts = value.split(separator: " ")
                guard counts.count == 2 else { return }
                ahead = Int(counts[0].dropFirst())
                behind = Int(counts[1].dropFirst())
            default: break // Newer headers (e.g. stash count) are not needed.
            }
        }
    }

    /// Every record type that occupies exactly one NUL-separated record.
    private static func singleRecordEntry(_ record: String) throws -> WorkingTreeStatus.Entry {
        if record.hasPrefix(StatusPrefix.changed) {
            return try entry(record, kind: .changed, fieldCount: StatusFieldCount.changed)
        }
        if record.hasPrefix(StatusPrefix.unmerged) {
            return try entry(record, kind: .unmerged, fieldCount: StatusFieldCount.unmerged)
        }
        if record.hasPrefix(StatusPrefix.untracked) {
            let path = String(record.dropFirst(StatusPrefix.untracked.count))
            return .init(kind: .untracked, state: StatusState.untracked, path: path, originalPath: nil)
        }
        if record.hasPrefix(StatusPrefix.ignored) {
            let path = String(record.dropFirst(StatusPrefix.ignored.count))
            return .init(kind: .ignored, state: StatusState.ignored, path: path, originalPath: nil)
        }
        throw GitError.unexpectedOutput(query: "status", detail: "unknown record '\(record.prefix(2))'")
    }

    /// Two-letter states git uses for untracked / ignored entries in porcelain v1, kept for display consistency.
    private enum StatusState {
        static let untracked = "??"
        static let ignored = "!!"
    }

    /// `fieldCount` space-separated fields precede the path; the path itself may contain spaces.
    private static func entry(_ record: String, kind: WorkingTreeStatus.EntryKind, fieldCount: Int) throws -> WorkingTreeStatus.Entry {
        let parts = record.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false)
        guard parts.count == fieldCount + 1 else {
            throw GitError.unexpectedOutput(query: "status", detail: "short record '\(record)'")
        }
        return .init(kind: kind, state: String(parts[1]), path: String(parts[fieldCount]), originalPath: nil)
    }

    // MARK: - log

    /// Unit separator between fields; commits are NUL-separated by `-z`. Subjects never contain U+001F.
    private static let unitSeparator = UInt8(0x1F)
    static let commitFormat = ["%H", "%an", "%ae", "%ct", "%s"].joined(separator: "%x1f")
    private static let commitFieldCount = 5

    public static func parseCommits(_ data: Data) throws -> [CommitSummary] {
        try data.split(separator: nul, omittingEmptySubsequences: true).map { record in
            // `-z` puts a newline before every record but the first; strip it so ids parse.
            let trimmed = record.drop { $0 == newline }
            let fields = trimmed.split(separator: unitSeparator, omittingEmptySubsequences: false).map { decode($0) }
            guard fields.count == commitFieldCount, isObjectID(fields[0]), let seconds = TimeInterval(fields[3]) else {
                throw GitError.unexpectedOutput(query: "log", detail: "malformed commit record")
            }
            return CommitSummary(id: fields[0], authorName: fields[1], authorEmail: fields[2],
                                 date: Date(timeIntervalSince1970: seconds), subject: fields[4])
        }
    }

    // MARK: - path lists (-z)

    /// NUL-separated paths, sorted for stable output.
    public static func parsePathList(_ data: Data) -> [String] {
        data.split(separator: nul, omittingEmptySubsequences: true).map { decode($0) }.sorted()
    }

    // MARK: - worktree list --porcelain -z

    private enum WorktreeField {
        static let worktree = "worktree "
        static let head = "HEAD "
        static let branch = "branch "
    }

    /// Records of NUL-terminated `key value` fields, each record ended by an empty field.
    public static func parseWorktrees(_ data: Data) -> [WorktreeInfo] {
        var worktrees: [WorktreeInfo] = []
        var path: String?
        var head: String?
        var branch: String?
        for field in data.split(separator: nul, omittingEmptySubsequences: false).map({ decode($0) }) {
            if field.isEmpty {
                if let path { worktrees.append(WorktreeInfo(path: path, headID: head, branchRef: branch)) }
                (path, head, branch) = (nil, nil, nil)
            } else if field.hasPrefix(WorktreeField.worktree) {
                path = String(field.dropFirst(WorktreeField.worktree.count))
            } else if field.hasPrefix(WorktreeField.head) {
                head = String(field.dropFirst(WorktreeField.head.count))
            } else if field.hasPrefix(WorktreeField.branch) {
                branch = String(field.dropFirst(WorktreeField.branch.count))
            }
        }
        if let path { worktrees.append(WorktreeInfo(path: path, headID: head, branchRef: branch)) }
        return worktrees
    }

    // MARK: - version

    public static func parseVersion(_ text: String) throws -> GitVersion {
        // "git version 2.50.1 (Apple Git-155)" / "git version 2.43.0.windows.1"
        let words = text.split(separator: " ")
        guard words.count >= 3, words[0] == "git", words[1] == "version" else {
            throw GitError.unexpectedOutput(query: "version", detail: text)
        }
        let numbers = words[2].split(separator: ".").prefix(3).map { Int($0.prefix { $0.isNumber }) }
        guard numbers.count >= 2, let major = numbers[0], let minor = numbers[1] else {
            throw GitError.unexpectedOutput(query: "version", detail: text)
        }
        let patch = numbers.count > 2 ? (numbers[2] ?? 0) : 0
        return GitVersion(major: major, minor: minor, patch: patch)
    }

    // MARK: - helpers

    static func trimmedLine(_ data: Data) -> String {
        decode(data).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SHA-1 (40) or SHA-256 (64) hex object id.
    static func isObjectID(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy(\.isHexDigit)
    }

    /// git paths are bytes; invalid UTF-8 is repaired rather than dropped so a path is never lost.
    private static func decode<Bytes: Collection>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        String(decoding: bytes, as: UTF8.self)
    }
}
