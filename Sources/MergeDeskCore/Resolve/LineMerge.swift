import Foundation

/// A file split into lines, keeping whether it ended with a newline, so joining gives back the exact bytes.
public struct TextLines: Equatable, Sendable {
    public var lines: [String]
    public var endsWithNewline: Bool

    public init(_ text: String) {
        var parts = text.components(separatedBy: "\n")
        endsWithNewline = text.hasSuffix("\n")
        if endsWithNewline { parts.removeLast() }
        lines = text.isEmpty ? [] : parts
    }

    public init(lines: [String], endsWithNewline: Bool) {
        self.lines = lines
        self.endsWithNewline = endsWithNewline
    }

    public var text: String { lines.joined(separator: "\n") + (endsWithNewline && !lines.isEmpty ? "\n" : "") }
}

/// Outcome of a three-way merge of one region.
public enum LineMergeResult: Equatable, Sendable {
    /// `pureInsertion`: neither side removed or changed a base line — the safest kind of merge.
    case merged([String], pureInsertion: Bool)
    case conflict(String)
}

/// Three-way merge of line sequences: keeps every line both sides kept, drops lines either side deleted, and
/// adds both sides' insertions (ours first, then theirs, skipping lines ours already added). Refuses when both
/// sides replaced the same base line differently.
public enum LineMerge {
    /// One side's edit of the base: deleted base indices, and lines inserted before base index `i`
    /// (`i == base.count` = at the end).
    struct Edit: Equatable {
        var deleted: Set<Int> = []
        var inserted: [Int: [String]] = [:]
    }

    public static func merge(base: [String], ours: [String], theirs: [String]) -> LineMergeResult {
        if ours == theirs { return .merged(ours, pureInsertion: true) }
        if ours == base { return .merged(theirs, pureInsertion: edit(base: base, side: theirs).deleted.isEmpty) }
        if theirs == base { return .merged(ours, pureInsertion: edit(base: base, side: ours).deleted.isEmpty) }

        let mine = edit(base: base, side: ours)
        let other = edit(base: base, side: theirs)
        if let reason = overlappingChange(base: base, mine, other) { return .conflict(reason) }

        var result: [String] = []
        for index in 0...base.count {
            let ourLines = mine.inserted[index] ?? []
            var remaining = ourLines
            result += ourLines
            for line in other.inserted[index] ?? [] {
                // Both sides added the same line here: keep it once.
                if let match = remaining.firstIndex(of: line) {
                    remaining.remove(at: match)
                } else {
                    result.append(line)
                }
            }
            if index < base.count, !mine.deleted.contains(index), !other.deleted.contains(index) {
                result.append(base[index])
            }
        }
        return .merged(result, pureInsertion: mine.deleted.isEmpty && other.deleted.isEmpty)
    }

    /// Both sides removed the same base line and replaced it incompatibly: one deleted it while the other
    /// changed it, or they put in replacements with no line in common (`v = 2` vs `v = 3`). Replacements that
    /// share a line (the same change, plus different additions) merge.
    private static func overlappingChange(base: [String], _ mine: Edit, _ other: Edit) -> String? {
        for index in mine.deleted.intersection(other.deleted).sorted() {
            let around = [index, index + 1]
            let ours = around.flatMap { mine.inserted[$0] ?? [] }
            let theirs = around.flatMap { other.inserted[$0] ?? [] }
            guard ours != theirs else { continue }
            let line = base[index].trimmingCharacters(in: .whitespaces)
            if ours.isEmpty != theirs.isEmpty {
                return "one side deleted the line '\(line)' that the other changed"
            }
            if Set(ours).isDisjoint(with: theirs) {
                return "both sides changed the line '\(line)' differently"
            }
        }
        return nil
    }

    /// Longest-common-subsequence alignment of `side` against `base` (regions are small: conflict hunks).
    static func edit(base: [String], side: [String]) -> Edit {
        let rows = base.count, columns = side.count
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: columns + 1), count: rows + 1)
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                lengths[row][column] = base[row] == side[column]
                    ? lengths[row + 1][column + 1] + 1
                    : max(lengths[row + 1][column], lengths[row][column + 1])
            }
        }
        var edit = Edit()
        var row = 0, column = 0
        while row < rows || column < columns {
            if row < rows, column < columns, base[row] == side[column] {
                row += 1
                column += 1
            } else if column < columns, row == rows || lengths[row][column + 1] >= lengths[row + 1][column] {
                edit.inserted[row, default: []].append(side[column])
                column += 1
            } else {
                edit.deleted.insert(row)
                row += 1
            }
        }
        return edit
    }

    /// Lines that assign the same key different values (`KEY = a;` vs `KEY = b;`, or one object id defined
    /// twice) — the merge kept both, which would be wrong.
    public static func conflictingAssignments(_ lines: [String]) -> [String] {
        var seen: [String: String] = [:]
        var clashes: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let range = trimmed.range(of: " = "), !trimmed.hasPrefix("/*") else { continue }
            // The key is the text before " = ", without a trailing `/* comment */`.
            var key = String(trimmed[..<range.lowerBound])
            if let comment = key.range(of: " /*") { key = String(key[..<comment.lowerBound]) }
            if let previous = seen[key], previous != trimmed {
                clashes.append(key)
            } else {
                seen[key] = trimmed
            }
        }
        return clashes
    }
}

/// A file as `git merge-file --diff3` leaves it: merged text with conflict blocks still to decide.
public struct ConflictedText: Equatable, Sendable {
    public enum Segment: Equatable, Sendable {
        case text([String])
        case conflict(ours: [String], base: [String], theirs: [String])
    }

    public let segments: [Segment]
    public let endsWithNewline: Bool

    /// Marker length well above git's default 7, so file content that happens to look like a marker can't be
    /// mistaken for one.
    public static let markerSize = 32
    /// `git merge-file` exits with the number of conflicts, capped here; anything else is an error.
    static let maxConflictCountExit: Int32 = 127
    /// Resolves one conflict block from its ours, base and theirs lines.
    public typealias BlockResolver = (_ ours: [String], _ base: [String], _ theirs: [String]) -> LineMergeResult
    static let ours = String(repeating: "<", count: markerSize)
    static let base = String(repeating: "|", count: markerSize)
    static let separator = String(repeating: "=", count: markerSize)
    static let theirs = String(repeating: ">", count: markerSize)

    public var conflictCount: Int {
        segments.filter { if case .conflict = $0 { return true } else { return false } }.count
    }

    /// Parses `git merge-file -p --diff3 --marker-size=32` output.
    public init(mergeFileOutput text: String) {
        let input = TextLines(text)
        var segments: [Segment] = []
        var plain: [String] = []
        // Lines of the block being read, by part.
        var block: [Part: [String]] = [:]
        var part = Part.none
        for line in input.lines {
            switch Self.marker(line, inConflict: part != .none) {
            case .start:
                if !plain.isEmpty { segments.append(.text(plain)) }
                (plain, block, part) = ([], [:], .ours)
            case .base:
                part = .base
            case .separator:
                part = .theirs
            case .end:
                segments.append(.conflict(ours: block[.ours] ?? [], base: block[.base] ?? [], theirs: block[.theirs] ?? []))
                part = .none
            case nil:
                if part == .none { plain.append(line) } else { block[part, default: []].append(line) }
            }
        }
        if !plain.isEmpty { segments.append(.text(plain)) }
        self.segments = segments
        self.endsWithNewline = input.endsWithNewline
    }

    private enum Part { case none, ours, base, theirs }
    private enum Marker { case start, base, separator, end }

    /// Which marker a line is; inner markers only count inside a block.
    private static func marker(_ line: String, inConflict: Bool) -> Marker? {
        if line.hasPrefix(ours) { return .start }
        guard inConflict else { return nil }
        if line.hasPrefix(base) { return .base }
        if line == separator { return .separator }
        if line.hasPrefix(theirs) { return .end }
        return nil
    }

    /// Runs `git merge-file` on three versions (no repository needed). Nil base = both sides added the file.
    public static func make(base: Data?, ours: Data, theirs: Data, git: GitClient) async throws -> ConflictedText {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mergedesk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = ["ours", "base", "theirs"].map { folder.appendingPathComponent($0) }
        try ours.write(to: files[0])
        try (base ?? Data()).write(to: files[1])
        try theirs.write(to: files[2])
        let result = try await git.run(["merge-file", "-p", "--diff3", "--marker-size=\(markerSize)",
                                        "-L", "ours", "-L", "base", "-L", "theirs"] + files.map(\.path), in: folder)
        // Exit status = number of conflicts (capped at 127); negative / >127 means an error.
        guard result.exitCode >= 0, result.exitCode <= maxConflictCountExit else {
            throw GitError.unexpectedOutput(query: "merge-file", detail: result.errorText)
        }
        return ConflictedText(mergeFileOutput: String(decoding: result.standardOutput, as: UTF8.self))
    }

    /// Resolves every block with `resolve`; nil if any block can't be resolved.
    public func resolved(_ resolve: BlockResolver) -> (text: String, pureInsertion: Bool)? {
        var lines: [String] = []
        var pure = true
        for segment in segments {
            switch segment {
            case let .text(text):
                lines += text
            case let .conflict(ours, base, theirs):
                guard case let .merged(merged, pureInsertion) = resolve(ours, base, theirs) else { return nil }
                lines += merged
                pure = pure && pureInsertion
            }
        }
        return (TextLines(lines: lines, endsWithNewline: endsWithNewline).text, pure)
    }

    /// The first unresolvable block's reason, for messages.
    public func firstConflictReason(_ resolve: BlockResolver) -> String? {
        for case let .conflict(ours, base, theirs) in segments {
            if case let .conflict(reason) = resolve(ours, base, theirs) { return reason }
        }
        return nil
    }
}
