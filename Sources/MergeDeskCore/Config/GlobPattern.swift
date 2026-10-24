import Foundation

/// Path glob used by `.mergedesk.json` file classes and protected-branch patterns.
///
/// Syntax (deliberately small and explicit — no implicit "match anywhere" like .gitignore):
/// - `*` any characters within one path segment
/// - `?` exactly one character within a segment
/// - `**` as a whole segment: zero or more segments
/// Matching is case-sensitive, like git.
public struct GlobPattern: Sendable, Equatable, Hashable, CustomStringConvertible {
    public enum CompileError: Error, Equatable, CustomStringConvertible {
        case empty
        case misplacedDoubleStar(pattern: String)
        case emptySegment(pattern: String)

        public var description: String {
            switch self {
            case .empty: return "pattern is empty"
            case let .misplacedDoubleStar(pattern): return "'**' must be a whole path segment in '\(pattern)'"
            case let .emptySegment(pattern): return "empty path segment ('//' or leading/trailing '/') in '\(pattern)'"
            }
        }
    }

    private enum Segment: Sendable, Equatable, Hashable {
        case anyDepth
        case pattern([Character])
    }

    private static let doubleStar = "**"
    private static let star: Character = "*"
    private static let question: Character = "?"

    public let pattern: String
    private let segments: [Segment]

    public init(_ pattern: String) throws {
        guard !pattern.isEmpty else { throw CompileError.empty }
        let parts = pattern.split(separator: "/", omittingEmptySubsequences: false)
        self.segments = try parts.map { part in
            guard !part.isEmpty else { throw CompileError.emptySegment(pattern: pattern) }
            if part == Self.doubleStar { return .anyDepth }
            if part.contains(Self.doubleStar) { throw CompileError.misplacedDoubleStar(pattern: pattern) }
            return .pattern(Array(part))
        }
        self.pattern = pattern
    }

    /// For patterns written in source code (built-in defaults). They are covered by tests, so an invalid one is a
    /// programming error and stops immediately rather than being silently skipped.
    init(staticPattern: String) {
        do {
            try self.init(staticPattern)
        } catch {
            preconditionFailure("invalid built-in glob '\(staticPattern)': \(error)")
        }
    }

    public var description: String { pattern }

    public func matches(_ path: String) -> Bool {
        let pathSegments = path.split(separator: "/", omittingEmptySubsequences: true).map { Array($0) }
        var memo: [Int: Bool] = [:]
        return match(segmentIndex: 0, pathIndex: 0, pathSegments: pathSegments, memo: &memo)
    }

    /// Segment-level matching; memoised on (segment, path) position so `**/**/…` stays linear-ish.
    private func match(segmentIndex: Int, pathIndex: Int, pathSegments: [[Character]], memo: inout [Int: Bool]) -> Bool {
        let key = segmentIndex * (pathSegments.count + 1) + pathIndex
        if let known = memo[key] { return known }
        let result: Bool
        if segmentIndex == segments.count {
            result = pathIndex == pathSegments.count
        } else {
            switch segments[segmentIndex] {
            case .anyDepth:
                // Zero segments, or consume one and stay on `**`.
                result = match(segmentIndex: segmentIndex + 1, pathIndex: pathIndex, pathSegments: pathSegments, memo: &memo)
                    || (pathIndex < pathSegments.count
                        && match(segmentIndex: segmentIndex, pathIndex: pathIndex + 1, pathSegments: pathSegments, memo: &memo))
            case let .pattern(characters):
                result = pathIndex < pathSegments.count
                    && Self.wildcardMatch(characters, pathSegments[pathIndex])
                    && match(segmentIndex: segmentIndex + 1, pathIndex: pathIndex + 1, pathSegments: pathSegments, memo: &memo)
            }
        }
        memo[key] = result
        return result
    }

    /// Classic `*` / `?` matcher with backtracking to the last star (linear in practice).
    private static func wildcardMatch(_ pattern: [Character], _ text: [Character]) -> Bool {
        var patternIndex = 0
        var textIndex = 0
        var starIndex: Int?
        var resumeText = 0
        while textIndex < text.count {
            // Star is checked first so a literal '*' in the text can't consume the pattern's star as a plain character.
            if patternIndex < pattern.count, pattern[patternIndex] == star {
                starIndex = patternIndex
                resumeText = textIndex
                patternIndex += 1
            } else if patternIndex < pattern.count,
                      pattern[patternIndex] == question || pattern[patternIndex] == text[textIndex] {
                patternIndex += 1
                textIndex += 1
            } else if let lastStar = starIndex {
                // Let the last star absorb one more character and retry from there.
                patternIndex = lastStar + 1
                resumeText += 1
                textIndex = resumeText
            } else {
                return false
            }
        }
        while patternIndex < pattern.count, pattern[patternIndex] == star { patternIndex += 1 }
        return patternIndex == pattern.count
    }
}

extension GlobPattern: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        do {
            try self.init(text)
        } catch let error as CompileError {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: error.description)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(pattern)
    }
}
