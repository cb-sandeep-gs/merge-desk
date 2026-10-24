import XCTest
@testable import MergeDeskCore

/// Byte-level parser tests: every format is fed exactly as git prints it (NUL-separated where `-z` is used).
final class GitOutputParserTests: XCTestCase {
    private let treeID = String(repeating: "a", count: 40)
    private let commitID = String(repeating: "b", count: 40)

    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    private func mergeTreeResult(_ text: String, exitCode: Int32) -> GitResult {
        GitResult(arguments: ["merge-tree"], exitCode: exitCode, standardOutput: bytes(text), standardError: Data())
    }

    // MARK: refs

    func testParseRefsReadsLocalAndRemoteAndSkipsSymbolicRefs() throws {
        let output = [
            "refs/heads/feature/x\0\(commitID)\01767225600\0Ana Dev\0<ana@example.com>\0refs/remotes/origin/feature/x\0",
            "refs/remotes/origin/HEAD\0\(commitID)\01767225600\0Ana Dev\0<ana@example.com>\0\0refs/remotes/origin/main",
            "refs/remotes/origin/release/1.2\0\(commitID)\01767225660\0Bo\0<bo@example.com>\0\0",
        ].joined(separator: "\n") + "\n"

        let refs = try GitOutputParser.parseRefs(bytes(output))

        XCTAssertEqual(refs.count, 2, "origin/HEAD is a symbolic ref and must not be listed")
        XCTAssertEqual(refs[0].kind, .local)
        XCTAssertEqual(refs[0].branchName, "feature/x")
        XCTAssertEqual(refs[0].shortName, "feature/x")
        XCTAssertEqual(refs[0].authorEmail, "ana@example.com")
        XCTAssertEqual(refs[0].upstream, "refs/remotes/origin/feature/x")
        XCTAssertEqual(refs[0].committerDate, Date(timeIntervalSince1970: 1_767_225_600))
        XCTAssertEqual(refs[1].kind, .remote(name: "origin"))
        XCTAssertEqual(refs[1].branchName, "release/1.2")
        XCTAssertEqual(refs[1].shortName, "origin/release/1.2")
        XCTAssertNil(refs[1].upstream)
    }

    func testParseRefsRejectsWrongFieldCount() {
        XCTAssertThrowsError(try GitOutputParser.parseRefs(bytes("refs/heads/x\0\(commitID)\n")))
    }

    func testParseRefsOfEmptyRepositoryIsEmpty() throws {
        XCTAssertEqual(try GitOutputParser.parseRefs(Data()), [])
    }

    // MARK: ahead / behind

    func testLeftRightCountMapsLeftToBehindAndRightToAhead() throws {
        XCTAssertEqual(try GitOutputParser.parseLeftRightCount(bytes("3\t5\n")), AheadBehind(ahead: 5, behind: 3))
    }

    func testLeftRightCountRejectsGarbage() {
        XCTAssertThrowsError(try GitOutputParser.parseLeftRightCount(bytes("fatal\n")))
    }

    // MARK: merge-tree

    func testMergeTreeCleanIsTreeOnly() throws {
        let result = try GitOutputParser.parseMergeTree(mergeTreeResult("\(treeID)\0", exitCode: 0))
        XCTAssertEqual(result.treeID, treeID)
        XCTAssertTrue(result.isClean)
        XCTAssertEqual(result.messages, [])
    }

    func testMergeTreeConflictReadsPathsAndMessages() throws {
        let output = "\(treeID)\0g.txt\0dir with space/f ü.swift\0\0"
            + "1\0g.txt\0CONFLICT (modify/delete)\0CONFLICT (modify/delete): g.txt deleted in side.\n\0"
            + "2\0a.txt\0b.txt\0CONFLICT (rename/rename)\0renamed both ways\n\0"

        let result = try GitOutputParser.parseMergeTree(mergeTreeResult(output, exitCode: 1))

        XCTAssertFalse(result.isClean)
        XCTAssertEqual(result.conflictedPaths, ["g.txt", "dir with space/f ü.swift"])
        XCTAssertEqual(result.messages.count, 2)
        XCTAssertEqual(result.messages[0].paths, ["g.txt"])
        XCTAssertEqual(result.messages[0].type, "CONFLICT (modify/delete)")
        XCTAssertEqual(result.messages[0].text, "CONFLICT (modify/delete): g.txt deleted in side.")
        XCTAssertEqual(result.messages[1].paths, ["a.txt", "b.txt"])
    }

    func testMergeTreeDeduplicatesRepeatedPaths() throws {
        let result = try GitOutputParser.parseMergeTree(mergeTreeResult("\(treeID)\0a\0a\0\0", exitCode: 1))
        XCTAssertEqual(result.conflictedPaths, ["a"])
    }

    /// git exits 1 both for conflicts and for errors like an unknown ref; only stdout tells them apart.
    func testMergeTreeExitOneWithEmptyOutputIsAnError() {
        let result = GitResult(arguments: ["merge-tree"], exitCode: 1, standardOutput: Data(),
                               standardError: bytes("merge-tree: nope - not something we can merge\n"))
        XCTAssertThrowsError(try GitOutputParser.parseMergeTree(result)) { error in
            guard case let GitError.commandFailed(_, code, message) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(code, 1)
            XCTAssertTrue(message.contains("not something we can merge"))
        }
    }

    func testMergeTreeRejectsMissingTreeAndBrokenMessages() {
        XCTAssertThrowsError(try GitOutputParser.parseMergeTree(mergeTreeResult("not-a-tree\0", exitCode: 0)))
        XCTAssertThrowsError(try GitOutputParser.parseMergeTree(mergeTreeResult("\(treeID)\0a\0\03\0a\0", exitCode: 1)))
    }

    // MARK: status

    func testStatusParsesHeadersAndEveryRecordType() throws {
        let records = [
            "# branch.oid \(commitID)",
            "# branch.head feature/x",
            "# branch.upstream origin/feature/x",
            "# branch.ab +2 -7",
            "1 .M N... 100644 100644 100644 \(commitID) \(commitID) dir with space/file.swift",
            "2 R. N... 100644 100644 100644 \(commitID) \(commitID) R100 new name.txt",
            "old name.txt",
            "u UU N... 100644 100644 100644 100644 \(commitID) \(commitID) \(commitID) conflicted.swift",
            "? new file.txt",
            "! ignored.log",
        ]
        let status = try GitOutputParser.parseStatus(bytes(records.joined(separator: "\0") + "\0"))

        XCTAssertEqual(status.branch, "feature/x")
        XCTAssertEqual(status.headObjectID, commitID)
        XCTAssertEqual(status.upstream, "origin/feature/x")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 7)
        XCTAssertEqual(status.entries.map(\.kind), [.changed, .renamedOrCopied, .unmerged, .untracked, .ignored])
        XCTAssertEqual(status.entries[0].path, "dir with space/file.swift")
        XCTAssertEqual(status.entries[0].state, ".M")
        XCTAssertEqual(status.entries[1].path, "new name.txt")
        XCTAssertEqual(status.entries[1].originalPath, "old name.txt")
        XCTAssertEqual(status.entries[2].state, "UU")
        XCTAssertTrue(status.hasConflicts)
        XCTAssertFalse(status.isClean)
    }

    func testStatusDetachedUnbornAndIgnoredOnlyIsClean() throws {
        let status = try GitOutputParser.parseStatus(bytes("# branch.oid (initial)\0# branch.head (detached)\0! build.log\0"))
        XCTAssertNil(status.branch)
        XCTAssertNil(status.headObjectID)
        XCTAssertTrue(status.isClean, "ignored files don't make a tree dirty")
    }

    func testStatusRejectsUnknownRecordsAndShortRecords() {
        XCTAssertThrowsError(try GitOutputParser.parseStatus(bytes("Z what\0")))
        XCTAssertThrowsError(try GitOutputParser.parseStatus(bytes("1 .M N...\0")))
        XCTAssertThrowsError(try GitOutputParser.parseStatus(bytes("2 R. N... 100644 100644 100644 \(commitID) \(commitID) R100 x\0")),
                             "a rename must be followed by its original path")
    }

    // MARK: version

    func testVersionVariants() throws {
        XCTAssertEqual(try GitOutputParser.parseVersion("git version 2.50.1 (Apple Git-155)\n"), GitVersion(major: 2, minor: 50, patch: 1))
        XCTAssertEqual(try GitOutputParser.parseVersion("git version 2.43.0.windows.1"), GitVersion(major: 2, minor: 43, patch: 0))
        XCTAssertEqual(try GitOutputParser.parseVersion("git version 2.39"), GitVersion(major: 2, minor: 39, patch: 0))
        XCTAssertThrowsError(try GitOutputParser.parseVersion("hg version 6"))
        XCTAssertLessThan(GitVersion(major: 2, minor: 37, patch: 9), MergeDeskConstants.minimumGitVersion)
    }
}
