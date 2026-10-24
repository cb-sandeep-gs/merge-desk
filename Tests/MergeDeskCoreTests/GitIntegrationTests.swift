import XCTest
@testable import MergeDeskCore
@testable import MergeDeskFixtures

/// End-to-end against real git: build every fixture repository, then run each query on it.
final class GitIntegrationTests: XCTestCase {
    private var folder: URL!
    private let git = ProcessGitClient(environmentOverrides: FixtureBuilder.isolatedEnvironment)

    override func setUpWithError() throws { folder = try TemporaryFolder.make() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testGitIsNewEnoughForConflictPrediction() async throws {
        let version = try await git.execute(.version, in: folder)
        XCTAssertGreaterThanOrEqual(version, MergeDeskConstants.minimumGitVersion)
    }

    /// The core MD-0 gate: every fixture builds and git reports exactly the conflicts the fixture declares.
    func testEveryFixturePredictsItsExpectedConflicts() async throws {
        let fixtures = try await FixtureBuilder().buildAll(in: folder)
        XCTAssertEqual(fixtures.count, FixturePattern.allCases.count)

        for fixture in fixtures {
            let definition = fixture.definition
            let query = GitQuery.mergeTree(target: definition.targetBranch, source: definition.sourceBranch)
            let result = try await git.execute(query, in: fixture.url)
            XCTAssertEqual(result.conflictedPaths.sorted(), definition.expectedConflicts.sorted(), definition.pattern.rawValue)
            XCTAssertEqual(result.isClean, definition.expectedConflicts.isEmpty, definition.pattern.rawValue)
            if !result.isClean {
                XCTAssertFalse(result.messages.isEmpty, "\(definition.pattern.rawValue): conflicts come with git's messages")
            }
            // Prediction must not touch the checkout.
            let status = try await git.execute(.status, in: fixture.url)
            XCTAssertTrue(status.isClean, definition.pattern.rawValue)
            XCTAssertEqual(status.branch, definition.targetBranch, definition.pattern.rawValue)
        }
    }

    func testBranchesAheadBehindAndAncestry() async throws {
        let fixture = try await FixtureBuilder().build(.revertOnOneSide, in: folder)
        let branches = try await git.execute(.branches(), in: fixture.url)

        XCTAssertEqual(Set(branches.map(\.branchName)), [FixtureBranch.base, FixtureBranch.target, FixtureBranch.source])
        XCTAssertTrue(branches.allSatisfy { $0.kind == .local && $0.authorEmail == "fixture@example.com" })

        let aheadBehind = try await git.execute(.aheadBehind(branch: FixtureBranch.target, base: FixtureBranch.source), in: fixture.url)
        XCTAssertEqual(aheadBehind, AheadBehind(ahead: 1, behind: 1))

        let baseMerged = try await git.execute(.isAncestor(FixtureBranch.base, of: FixtureBranch.target), in: fixture.url)
        let sourceMerged = try await git.execute(.isAncestor(FixtureBranch.source, of: FixtureBranch.target), in: fixture.url)
        XCTAssertTrue(baseMerged)
        XCTAssertFalse(sourceMerged)

        let baseID = try await git.execute(.commitID(of: FixtureBranch.base), in: fixture.url)
        let mergeBase = try await git.execute(.mergeBase(FixtureBranch.target, FixtureBranch.source), in: fixture.url)
        XCTAssertEqual(mergeBase, baseID)
    }

    func testUnicodeBranchNamesAndPathsSurvive() async throws {
        let fixture = try await FixtureBuilder().build(.awkwardNames, in: folder)
        let branches = try await git.execute(.branches(), in: fixture.url)
        XCTAssertTrue(branches.contains { $0.branchName == "feature/ünïcode-source" })

        let path = "dir with space/naïve file ü.txt"
        try Data("edited\n".utf8).write(to: fixture.url.appendingPathComponent(path))
        let status = try await git.execute(.status, in: fixture.url)
        XCTAssertEqual(status.entries.map(\.path), [path])
        XCTAssertFalse(status.isClean)
    }

    /// Same steps → same commit ids on any machine: fixtures are reproducible, so golden files stay valid.
    func testFixturesAreDeterministic() async throws {
        let first = try await FixtureBuilder().build(.cherryPicked, in: folder.appendingPathComponent("one"))
        let second = try await FixtureBuilder().build(.cherryPicked, in: folder.appendingPathComponent("two"))
        let firstTip = try await git.execute(.commitID(of: FixtureBranch.target), in: first.url)
        let secondTip = try await git.execute(.commitID(of: FixtureBranch.target), in: second.url)
        XCTAssertEqual(firstTip, secondTip)
    }

    func testBuilderNeverOverwritesAnExistingFolder() async throws {
        _ = try await FixtureBuilder().build(.cleanMerge, in: folder)
        do {
            _ = try await FixtureBuilder().build(.cleanMerge, in: folder)
            XCTFail("expected destinationExists")
        } catch let error as FixtureError {
            XCTAssertEqual(error, .destinationExists(folder.appendingPathComponent(FixturePattern.cleanMerge.rawValue).path))
        }
    }

    func testUnknownRefIsAnErrorNotAConflict() async throws {
        let fixture = try await FixtureBuilder().build(.cleanMerge, in: folder)
        do {
            _ = try await git.execute(.mergeTree(target: FixtureBranch.target, source: "does-not-exist"), in: fixture.url)
            XCTFail("expected an error")
        } catch let GitError.commandFailed(_, exitCode, _) {
            XCTAssertEqual(exitCode, GitExitCode.one)
        }
    }

    func testRepositoryRootAndNonRepository() async throws {
        let fixture = try await FixtureBuilder().build(.cleanMerge, in: folder)
        let nested = fixture.url.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let root = try await git.execute(.repositoryRoot, in: nested)
        XCTAssertEqual(root.standardizedFileURL.path, fixture.url.standardizedFileURL.path)

        let outside = folder.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        do {
            _ = try await git.execute(.repositoryRoot, in: outside)
            XCTFail("expected an error outside a repository")
        } catch is GitError {}
    }

    func testMissingExecutableIsALaunchError() async throws {
        let broken = ProcessGitClient(executableURL: URL(fileURLWithPath: "/nonexistent/git"))
        do {
            _ = try await broken.run(["version"], in: folder)
            XCTFail("expected launchFailed")
        } catch GitError.launchFailed(let executable, _) {
            XCTAssertEqual(executable, "/nonexistent/git")
        }
    }

    /// Cancelling the task stops git and surfaces CancellationError, never half-read output.
    func testCancellationStopsTheProcess() async throws {
        let sleeper = ProcessGitClient(executableURL: URL(fileURLWithPath: "/bin/sleep"))
        let directory: URL = folder
        let task = Task { try await sleeper.run(["30"], in: directory) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(started), 5, "process must be terminated promptly")
        }
    }
}
