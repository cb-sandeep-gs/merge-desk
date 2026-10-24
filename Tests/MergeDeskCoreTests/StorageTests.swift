import XCTest
@testable import MergeDeskCore

/// Temp folders under the system temp dir; each test removes its own.
enum TemporaryFolder {
    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mergedesk-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Resolve /var → /private/var so paths compare equal to what git reports.
        return url.resolvingSymlinksInPath()
    }
}

final class AuditLogTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws { folder = try TemporaryFolder.make() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// Whole seconds: ISO-8601 in the log drops sub-second precision.
    private func event(_ action: AuditAction, seconds: TimeInterval = 1_767_225_600) -> AuditEvent {
        AuditEvent(timestamp: Date(timeIntervalSince1970: seconds), user: "tester", action: action, branch: "feature/x",
                   objectIDBefore: "a", objectIDAfter: "b", backupRef: "refs/mergedesk/backup/x", details: ["tier": "1"])
    }

    func testMissingLogReadsAsEmpty() async throws {
        let log = AuditLog(fileURL: folder.appendingPathComponent("none/audit.jsonl"))
        let contents = try await log.readAll()
        XCTAssertEqual(contents, AuditLogContents(events: [], unreadableLineCount: 0))
    }

    func testAppendCreatesFoldersAndRoundTrips() async throws {
        let log = AuditLog(fileURL: folder.appendingPathComponent("repos/r/audit.jsonl"))
        let first = event(.mergeApplied)
        let second = event(.mergeUndone, seconds: 1_767_225_660)
        try await log.append(first)
        try await log.append(second)

        let contents = try await log.readAll()
        XCTAssertEqual(contents.events, [first, second])
        XCTAssertEqual(contents.unreadableLineCount, 0)
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2, "one event per line")
    }

    /// A crash mid-write leaves a partial line; the next event must still land on its own line.
    func testTruncatedLineIsSkippedAndNextEventStaysReadable() async throws {
        let url = folder.appendingPathComponent("audit.jsonl")
        try Data(#"{"action":"merge.applied","id":"#.utf8).write(to: url)
        let log = AuditLog(fileURL: url)
        let next = event(.backupCreated)
        try await log.append(next)

        let contents = try await log.readAll()
        XCTAssertEqual(contents.events, [next])
        XCTAssertEqual(contents.unreadableLineCount, 1)
    }

    /// Logs written by a newer version (new action names) still decode.
    func testUnknownActionsDecode() async throws {
        let log = AuditLog(fileURL: folder.appendingPathComponent("audit.jsonl"))
        let future = event(AuditAction(rawValue: "future.action"))
        try await log.append(future)
        let contents = try await log.readAll()
        XCTAssertEqual(contents.events.first?.action.rawValue, "future.action")
    }

    func testConcurrentAppendsNeverInterleave() async throws {
        let log = AuditLog(fileURL: folder.appendingPathComponent("audit.jsonl"))
        let count = 50
        // Events are built up front so the child tasks capture only Sendable values, not the test case.
        let events = (0..<count).map { event(.fileResolved, seconds: TimeInterval(1_767_225_600 + $0)) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for item in events {
                group.addTask { try await log.append(item) }
            }
            try await group.waitForAll()
        }
        let contents = try await log.readAll()
        XCTAssertEqual(contents.events.count, count)
        XCTAssertEqual(contents.unreadableLineCount, 0)
    }
}

final class SupportPathsTests: XCTestCase {
    func testIdentifierIsStableReadableAndUniquePerPath() {
        let first = URL(fileURLWithPath: "/work/a/Mercury-iOSApp")
        let second = URL(fileURLWithPath: "/work/b/Mercury-iOSApp")
        let id = SupportPaths.repositoryIdentifier(for: first)

        XCTAssertEqual(id, SupportPaths.repositoryIdentifier(for: first))
        XCTAssertNotEqual(id, SupportPaths.repositoryIdentifier(for: second), "same folder name, different clone")
        XCTAssertTrue(id.hasPrefix("Mercury-iOSApp-"))
        XCTAssertEqual(id.count, "Mercury-iOSApp-".count + MergeDeskConstants.repositoryIdentifierHashLength)
    }

    /// Spaces and punctuation become `_`; letters (including non-ASCII ones) are valid folder characters and stay.
    func testIdentifierReplacesUnsafeCharacters() {
        let id = SupportPaths.repositoryIdentifier(for: URL(fileURLWithPath: "/work/my repo:ü"))
        XCTAssertTrue(id.hasPrefix("my_repo_ü-"), id)
    }

    func testPathsLiveUnderTheRootNeverInTheRepository() {
        let root = URL(fileURLWithPath: "/tmp/support", isDirectory: true)
        let repository = URL(fileURLWithPath: "/work/repo", isDirectory: true)
        let paths = SupportPaths(root: root)
        XCTAssertTrue(paths.auditLog(for: repository).path.hasPrefix(root.path))
        XCTAssertEqual(paths.auditLog(for: repository).lastPathComponent, MergeDeskConstants.auditLogFileName)
        XCTAssertTrue(SupportPaths.isRunningTests)
        XCTAssertTrue(SupportPaths().root.path.hasPrefix(FileManager.default.temporaryDirectory.path),
                      "in a test process the default folder is temporary, never the real support folder")
    }
}
