import Foundation

/// For one conflict block: which side's lines to keep.
public enum BlockChoice: String, CaseIterable, Sendable, Codable {
    /// The branch being merged into ("ours").
    case into
    /// The branch being merged in ("theirs").
    case from
    /// Both: the "into" lines, then the "from" lines.
    case both
}

/// One conflict block with a little surrounding text, for showing a person what to decide.
public struct ConflictBlock: Sendable, Equatable, Identifiable {
    public let id: Int
    public let into: [String]
    public let base: [String]
    public let from: [String]
    /// Up to `ConflictedText.contextLineCount` unchanged lines before and after the block.
    public let before: [String]
    public let after: [String]
}

extension ConflictedText {
    /// Unchanged lines shown around a block.
    public static let contextLineCount = 3

    /// The conflict blocks in file order, with context.
    public var blocks: [ConflictBlock] {
        var result: [ConflictBlock] = []
        for (index, segment) in segments.enumerated() {
            guard case let .conflict(ours, base, theirs) = segment else { continue }
            var before: [String] = []
            var after: [String] = []
            if index > 0, case let .text(lines) = segments[index - 1] { before = Array(lines.suffix(Self.contextLineCount)) }
            if index + 1 < segments.count, case let .text(lines) = segments[index + 1] {
                after = Array(lines.prefix(Self.contextLineCount))
            }
            result.append(ConflictBlock(id: result.count, into: ours, base: base, from: theirs, before: before, after: after))
        }
        return result
    }

    /// The file with each block replaced by the chosen side; nil if `choices` doesn't cover every block.
    public func render(choices: [BlockChoice]) -> String? {
        guard choices.count == conflictCount else { return nil }
        var lines: [String] = []
        var next = choices.makeIterator()
        for segment in segments {
            switch segment {
            case let .text(text):
                lines += text
            case let .conflict(ours, _, theirs):
                switch next.next() {
                case .into: lines += ours
                case .from: lines += theirs
                case .both: lines += ours + theirs
                case nil: return nil
                }
            }
        }
        return TextLines(lines: lines, endsWithNewline: endsWithNewline).text
    }
}

/// What a person sees for one conflicted file.
public enum FileConflict: Sendable, Equatable {
    /// Text with conflict blocks to choose from.
    case text(ConflictedText)
    /// The file exists on only one side (deleted on the other): keep it or delete it.
    case presentOnOneSide(inInto: Bool, inFrom: Bool)
    /// Binary content: pick a whole side.
    case binary
}

/// A whole side of a conflicted file.
public enum ConflictSide: String, Sendable, Codable {
    case into
    case from
}
