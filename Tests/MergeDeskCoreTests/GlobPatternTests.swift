import XCTest
@testable import MergeDeskCore

final class GlobPatternTests: XCTestCase {
    private func assertGlob(
        _ pattern: String, matches: [String], rejects: [String], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let glob = try GlobPattern(pattern)
        for path in matches { XCTAssertTrue(glob.matches(path), "\(pattern) should match \(path)", file: file, line: line) }
        for path in rejects { XCTAssertFalse(glob.matches(path), "\(pattern) should not match \(path)", file: file, line: line) }
    }

    func testDoubleStarMatchesAnyDepthIncludingZero() throws {
        try assertGlob("**/*.generated.swift",
                       matches: ["A.generated.swift", "Source/A.generated.swift", "a/b/c/Index.generated.swift"],
                       rejects: ["A.swift", "a/generated.swift/x", "A.generated.swiftx"])
        try assertGlob("Source/**/Docs/*.md",
                       matches: ["Source/Docs/a.md", "Source/x/y/Docs/b.md"],
                       rejects: ["Docs/a.md", "Source/Docs/sub/a.md"])
        try assertGlob("**", matches: ["a", "a/b/c"], rejects: [])
    }

    func testStarAndQuestionStayWithinOneSegment() throws {
        try assertGlob("release/*", matches: ["release/1.2", "release/x"], rejects: ["release", "release/1/2", "hotfix/1"])
        try assertGlob("Source/Documentation/catalogs/*.md",
                       matches: ["Source/Documentation/catalogs/CBZRoute-Catalog.md"],
                       rejects: ["Source/Documentation/catalogs/sub/x.md", "Source/Documentation/catalogs/x.json"])
        try assertGlob("v?.md", matches: ["v1.md"], rejects: ["v10.md", "v.md"])
        try assertGlob("a*b*c", matches: ["abc", "aXbYc", "abbbc"], rejects: ["acb", "ab"])
    }

    func testLiteralsAreExactAndCaseSensitive() throws {
        try assertGlob("main", matches: ["main"], rejects: ["Main", "main2", "x/main"])
        try assertGlob("dir with space/naïve ü.txt", matches: ["dir with space/naïve ü.txt"], rejects: ["dir with space/naive u.txt"])
    }

    func testStarStillMatchesALiteralStarInText() throws {
        try assertGlob("a*", matches: ["a*", "a**x"], rejects: ["b*"])
    }

    func testInvalidPatternsAreRejected() {
        XCTAssertThrowsError(try GlobPattern("")) { XCTAssertEqual($0 as? GlobPattern.CompileError, .empty) }
        XCTAssertThrowsError(try GlobPattern("a/**b")) {
            XCTAssertEqual($0 as? GlobPattern.CompileError, .misplacedDoubleStar(pattern: "a/**b"))
        }
        XCTAssertThrowsError(try GlobPattern("a//b"))
        XCTAssertThrowsError(try GlobPattern("/abs"))
    }

    func testCodableRoundTripAndDecodingErrors() throws {
        let glob = try GlobPattern("**/*.pbxproj")
        let data = try JSONEncoder().encode([glob])
        XCTAssertEqual(try JSONDecoder().decode([GlobPattern].self, from: data), [glob])
        XCTAssertThrowsError(try JSONDecoder().decode([GlobPattern].self, from: Data(#"["a/**b"]"#.utf8)))
    }
}
