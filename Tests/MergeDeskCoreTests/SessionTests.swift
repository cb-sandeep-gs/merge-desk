import XCTest
@testable import MergeDeskCore
@testable import MergeDeskFixtures

/// Merge sessions end to end against real git (fixture repositories and an origin + clone).
final class SessionTests: XCTestCase {
    private typealias Branch = InventoryFixture.Branch

    private var folder: URL!
    private let git = ProcessGitClient(environmentOverrides: FixtureBuilder.isolatedEnvironment)
    /// No `gh` in tests: the pull-request route uses the compare URL.
    private let noGitHubCLI = GitHubCLI(executableURL: nil)

    override func setUpWithError() throws { folder = try TemporaryFolder.make() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private var paths: SupportPaths { SupportPaths(root: folder.appendingPathComponent("support")) }

    /// Fixture repo whose `target` branch is an ordinary (unprotected) branch.
    private func fixture(_ pattern: FixturePattern) async throws -> (FixtureRepository, SessionManager) {
        let fixture = try await FixtureBuilder().build(pattern, in: folder)
        var config = RepoConfig.defaults
        config.integrationBranches = [fixture.definition.targetBranch]
        config.protectedBranches = []
        let manager = SessionManager(repositoryRoot: fixture.url, config: config, git: git, paths: paths, github: noGitHubCLI)
        return (fixture, manager)
    }

    private func sha(_ revision: String, in root: URL) async throws -> String {
        try await git.execute(.commitID(of: revision), in: root)
    }

    private func refExists(_ ref: String, in root: URL) async throws -> Bool {
        try await git.run(["rev-parse", "--verify", "--quiet", ref], in: root).exitCode == 0
    }

    // MARK: - The MD-3 gate: merge → undo restores the exact commit

    func testCleanMergeApplyUndoRestoresTheExactCommit() async throws {
        let (fixture, manager) = try await fixture(.cleanMerge)
        let root = fixture.url
        let originalTarget = try await sha(FixtureBranch.target, in: root)
        let sourceID = try await sha(FixtureBranch.source, in: root)

        var session = try await manager.plan(source: FixtureBranch.source, target: FixtureBranch.target)
        XCTAssertEqual(session.state, .planned)
        XCTAssertFalse(session.viaPullRequest)

        session = try await manager.start(session.id, fetch: false)
        XCTAssertEqual(session.state, .ready)
        let result = try XCTUnwrap(session.resultID)
        let worktree = try XCTUnwrap(session.worktreePath)
        XCTAssertFalse(worktree.hasPrefix(root.path), "the merge happens outside the repository")
        let afterStart = try await sha(FixtureBranch.target, in: root)
        XCTAssertEqual(afterStart, originalTarget, "nothing changes in the repository before Apply")
        let parents = try await git.run(["rev-list", "--parents", "-n", "1", result], in: root)
        XCTAssertEqual(String(decoding: parents.standardOutput, as: UTF8.self).split(separator: " ").dropFirst().map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) }, [originalTarget, sourceID])
        let sessionRefExists = try await refExists(SessionNaming.sessionRef(session.id), in: root)
        XCTAssertTrue(sessionRefExists, "the result is kept reachable while the session is open")

        // The fixture checkout is on `target`: Apply must refuse to move a checked-out branch.
        do {
            _ = try await manager.apply(session.id)
            XCTFail("expected branchCheckedOut")
        } catch let SessionError.branchCheckedOut(branch, _) {
            XCTAssertEqual(branch, FixtureBranch.target)
        }
        _ = try await git.run(["switch", "--quiet", FixtureBranch.base], in: root)

        session = try await manager.apply(session.id)
        XCTAssertEqual(session.state, .applied)
        let applied = try await sha(FixtureBranch.target, in: root)
        XCTAssertEqual(applied, result)
        guard case let .movedBranch(_, previous, backup) = session.applied else { return XCTFail("expected a moved branch") }
        XCTAssertEqual(previous, originalTarget)
        let backupID = try await sha(backup, in: root)
        XCTAssertEqual(backupID, originalTarget, "the backup ref holds the old commit")
        XCTAssertTrue(backup.hasPrefix(MergeDeskConstants.backupRefNamespace + "/"))
        XCTAssertNil(session.worktreePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree), "the worktree is removed after Apply")

        session = try await manager.undo(session.id)
        XCTAssertEqual(session.state, .undone)
        let restored = try await sha(FixtureBranch.target, in: root)
        XCTAssertEqual(restored, originalTarget, "undo restores the exact commit")
        let refAfterUndo = try await refExists(SessionNaming.sessionRef(session.id), in: root)
        XCTAssertFalse(refAfterUndo)

        do {
            _ = try await manager.undo(session.id)
            XCTFail("a finished session can't be undone twice")
        } catch SessionError.invalidTransition(.undone, .undone) {}

        let audit = try await AuditLog(fileURL: paths.auditLog(for: root)).readAll()
        XCTAssertEqual(audit.events.map(\.action), [.sessionPlanned, .mergeApplied, .mergeUndone])
        XCTAssertEqual(session.history.map(\.state), [.planned, .preflight, .merging, .verifying, .ready, .applied, .undone])
    }

    func testConflictsMustBeResolvedBeforeContinuing() async throws {
        let (fixture, manager) = try await fixture(.contentConflict)
        var session = try await manager.plan(source: FixtureBranch.source, target: FixtureBranch.target)
        session = try await manager.start(session.id, fetch: false)
        XCTAssertEqual(session.state, .resolving)
        XCTAssertEqual(session.conflictedFiles, ["Sources/App.swift"])
        let worktree = URL(fileURLWithPath: try XCTUnwrap(session.worktreePath))

        do {
            _ = try await manager.continueAfterResolving(session.id)
            XCTFail("markers are still in the file")
        } catch SessionError.unresolved(let files) {
            XCTAssertEqual(files, ["Sources/App.swift"])
        }

        let resolved = "let timeout = 15\nlet retries = 3\nlet host = \"api\"\n"
        try Data(resolved.utf8).write(to: worktree.appendingPathComponent("Sources/App.swift"))
        session = try await manager.continueAfterResolving(session.id)
        XCTAssertEqual(session.state, .ready)
        let content = try await git.run(["show", "\(try XCTUnwrap(session.resultID)):Sources/App.swift"], in: fixture.url)
        XCTAssertEqual(String(decoding: content.standardOutput, as: UTF8.self), resolved)
    }

    func testSquashMakesASingleParentCommit() async throws {
        let (fixture, manager) = try await fixture(.cleanMerge)
        let base = try await sha(FixtureBranch.target, in: fixture.url)
        var session = try await manager.plan(source: FixtureBranch.source, target: FixtureBranch.target, strategy: .squash)
        session = try await manager.start(session.id, fetch: false)
        let parents = try await git.run(["rev-list", "--parents", "-n", "1", try XCTUnwrap(session.resultID)], in: fixture.url)
        XCTAssertEqual(String(decoding: parents.standardOutput, as: UTF8.self).split(separator: " ").count, 2, "commit + one parent")
        XCTAssertTrue(String(decoding: parents.standardOutput, as: UTF8.self).contains(base))
        XCTAssertTrue(session.title.hasPrefix("Squash merge"))
    }

    func testApplyRefusesWhenTheTargetMovedAndLeavesNoBackup() async throws {
        let (fixture, manager) = try await fixture(.cleanMerge)
        let root = fixture.url
        var session = try await manager.plan(source: FixtureBranch.source, target: FixtureBranch.target)
        session = try await manager.start(session.id, fetch: false)
        // Someone commits to the target meanwhile.
        try Data("new\n".utf8).write(to: root.appendingPathComponent("Other.txt"))
        _ = try await git.run(["add", "--all"], in: root)
        _ = try await git.run(["commit", "--quiet", "-m", "meanwhile"], in: root)
        _ = try await git.run(["switch", "--quiet", FixtureBranch.base], in: root)
        let moved = try await sha(FixtureBranch.target, in: root)

        do {
            _ = try await manager.apply(session.id)
            XCTFail("expected branchMoved")
        } catch let SessionError.branchMoved(branch, _, actual) {
            XCTAssertEqual(branch, FixtureBranch.target)
            XCTAssertEqual(actual, moved)
        }
        let afterRefusal = try await sha(FixtureBranch.target, in: root)
        XCTAssertEqual(afterRefusal, moved, "the target is untouched")
        let backups = try await git.run(["for-each-ref", MergeDeskConstants.backupRefNamespace], in: root)
        XCTAssertTrue(backups.standardOutput.isEmpty, "a refused apply leaves no backup ref")
        XCTAssertEqual(try manager.store.load(session.id).state, .ready, "still ready: abort or start again")
    }

    func testAbortRemovesTheWorktree() async throws {
        let (fixture, manager) = try await fixture(.contentConflict)
        var session = try await manager.plan(source: FixtureBranch.source, target: FixtureBranch.target)
        session = try await manager.start(session.id, fetch: false)
        let worktree = try XCTUnwrap(session.worktreePath)
        session = try await manager.abort(session.id)
        XCTAssertEqual(session.state, .aborted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree))
        let worktrees = try await git.execute(.worktrees, in: fixture.url)
        XCTAssertEqual(worktrees.count, 1, "only the main checkout is left")
        do {
            _ = try await manager.abort(session.id)
            XCTFail("aborting twice is refused")
        } catch SessionError.invalidTransition {}
    }

    func testPlanRefusesNothingToMergeUnknownAndSameBranch() async throws {
        let (_, manager) = try await fixture(.cleanMerge)
        do {
            _ = try await manager.plan(source: FixtureBranch.base, target: FixtureBranch.target)
            XCTFail("base is already in target")
        } catch SessionError.nothingToMerge {}
        do {
            _ = try await manager.plan(source: "nope", target: FixtureBranch.target)
            XCTFail("unknown branch")
        } catch SessionError.unknownBranch("nope") {}
        do {
            _ = try await manager.plan(source: FixtureBranch.target, target: FixtureBranch.target)
            XCTFail("same branch")
        } catch SessionError.sameBranch {}
    }

    // MARK: - Push and the pull-request route (origin + clone)

    /// The other MD-3 gate: a protected target is never pushed directly; it gets a branch and a pull request.
    func testProtectedTargetGoesThroughAPullRequest() async throws {
        let inventory = try await InventoryFixture.build(in: folder)
        let clone = inventory.clone
        // Fetch from the local origin, but report a GitHub URL so the compare page can be built.
        let originPath = inventory.origin.path
        _ = try await git.run(["remote", "set-url", "origin", "git@github.com:cricbuzz/demo.git"], in: clone)
        _ = try await git.run(["remote", "set-url", "--push", "origin", originPath], in: clone)
        _ = try await git.run(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"], in: clone)
        let manager = SessionManager(repositoryRoot: clone, config: .defaults, git: git, paths: paths, github: noGitHubCLI)
        let developBefore = try await sha("refs/heads/develop", in: clone)

        var session = try await manager.plan(source: Branch.active, target: Branch.develop)
        XCTAssertTrue(session.viaPullRequest)
        session = try await manager.start(session.id, fetch: false)
        XCTAssertEqual(session.state, .ready)

        session = try await manager.apply(session.id)
        let prBranch = try XCTUnwrap(session.pullRequestBranch)
        XCTAssertEqual(session.applied, .createdBranch(branch: prBranch))
        XCTAssertTrue(prBranch.hasPrefix(SessionNaming.pullRequestBranchPrefix))
        let developAfter = try await sha("refs/heads/develop", in: clone)
        XCTAssertEqual(developAfter, developBefore, "the protected branch itself never moves")

        do {
            _ = try await manager.push(session.id, confirmed: true)
            XCTFail("direct push to a protected branch must be refused")
        } catch SessionError.protectedBranch(Branch.develop) {}
        do {
            _ = try await manager.openPullRequest(session.id, confirmed: false)
            XCTFail("needs confirmation")
        } catch SessionError.notConfirmed {}

        session = try await manager.openPullRequest(session.id, confirmed: true)
        XCTAssertEqual(session.state, .pullRequestOpened)
        XCTAssertEqual(session.pullRequestURL, "https://github.com/cricbuzz/demo/compare/develop...\(prBranch)?expand=1")
        let pushed = try await git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(prBranch)"], in: inventory.origin)
        XCTAssertEqual(pushed.exitCode, 0, "the merge branch is on the remote")
        let originDevelop = try await sha("refs/heads/develop", in: inventory.origin)
        XCTAssertEqual(originDevelop, developBefore, "the remote's develop is untouched")
    }

    func testUnprotectedPushNeedsConfirmationAndEndsUndo() async throws {
        let inventory = try await InventoryFixture.build(in: folder)
        let manager = SessionManager(repositoryRoot: inventory.clone, config: .defaults, git: git, paths: paths, github: noGitHubCLI)
        var session = try await manager.plan(source: Branch.stale, target: Branch.localOnly)
        session = try await manager.start(session.id, fetch: true)
        session = try await manager.apply(session.id)
        do {
            _ = try await manager.push(session.id, confirmed: false)
            XCTFail("needs confirmation")
        } catch SessionError.notConfirmed {}
        session = try await manager.push(session.id, confirmed: true)
        XCTAssertEqual(session.state, .pushed)
        let remote = try await sha("refs/heads/\(Branch.localOnly)", in: inventory.origin)
        XCTAssertEqual(remote, session.resultID)
        do {
            _ = try await manager.undo(session.id)
            XCTFail("a pushed merge can't be undone locally")
        } catch SessionError.invalidTransition(.pushed, .undone) {}
    }

    func testRemoteOnlyTargetIsCreatedLocallyAndUndoDeletesIt() async throws {
        let inventory = try await InventoryFixture.build(in: folder)
        let manager = SessionManager(repositoryRoot: inventory.clone, config: .defaults, git: git, paths: paths, github: noGitHubCLI)
        var session = try await manager.plan(source: Branch.localOnly, target: Branch.remoteOnly)
        session = try await manager.start(session.id, fetch: false)
        XCTAssertNil(session.targetLocalID)
        session = try await manager.apply(session.id)
        XCTAssertEqual(session.applied, .createdBranch(branch: Branch.remoteOnly))
        let upstream = try await git.run(["rev-parse", "--abbrev-ref", "\(Branch.remoteOnly)@{upstream}"], in: inventory.clone)
        XCTAssertEqual(GitOutputParser.trimmedLine(upstream.standardOutput), "origin/\(Branch.remoteOnly)")
        session = try await manager.undo(session.id)
        let exists = try await refExists("refs/heads/\(Branch.remoteOnly)", in: inventory.clone)
        XCTAssertFalse(exists, "undo deletes the branch it created")
    }

}

/// Pure session model rules (no git).
final class SessionModelTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws { folder = try TemporaryFolder.make() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private var paths: SupportPaths { SupportPaths(root: folder.appendingPathComponent("support")) }

    func testStateMachine() {
        XCTAssertTrue(SessionStateMachine.canTransition(from: .ready, to: .applied))
        XCTAssertFalse(SessionStateMachine.canTransition(from: .planned, to: .applied), "no skipping the merge")
        XCTAssertFalse(SessionStateMachine.canTransition(from: .applied, to: .aborted), "after Apply it's undo, not abort")
        XCTAssertFalse(SessionStateMachine.canTransition(from: .pushed, to: .undone))
        for state in SessionState.allCases where state.isFinished {
            XCTAssertTrue(SessionStateMachine.transitions[state, default: []].isEmpty, "\(state) is final")
        }
        XCTAssertEqual(Set(SessionStateMachine.transitions.keys), Set(SessionState.allCases))
    }

    func testStoreFindsByShortIDAndSortsNewestFirst() throws {
        let store = SessionStore(paths: paths, repositoryRoot: folder)
        let older = MergeSession(repositoryPath: folder.path, source: "a", target: "b", strategy: .mergeCommit,
                                 viaPullRequest: false, now: Date(timeIntervalSince1970: 1_000))
        let newer = MergeSession(repositoryPath: folder.path, source: "c", target: "b", strategy: .squash,
                                 viaPullRequest: true, now: Date(timeIntervalSince1970: 2_000))
        try store.save(older)
        try store.save(newer)
        XCTAssertEqual(store.all().map(\.id), [newer.id, older.id])
        XCTAssertEqual(store.find(older.shortID)?.id, older.id)
        XCTAssertEqual(try store.load(newer.id), newer)
    }

    func testNamesAndMarkers() throws {
        let id = try XCTUnwrap(UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000"))
        XCTAssertEqual(SessionNaming.pullRequestBranch(source: "feature/x y", target: "develop", id: id),
                       "mergedesk/feature-x-y-into-develop-abcdef12")
        XCTAssertEqual(SessionNaming.backupRef(branch: "feature/x", at: Date(timeIntervalSince1970: 0)),
                       "refs/mergedesk/backup/19700101-000000/feature/x")
        let file = folder.appendingPathComponent("f.txt")
        try Data("a\n<<<<<<< HEAD\nb\n=======\nc\n>>>>>>> x\n".utf8).write(to: file)
        XCTAssertTrue(SessionManager.hasConflictMarkers(file))
        try Data("# Title\n=======\nok\n".utf8).write(to: file)
        XCTAssertFalse(SessionManager.hasConflictMarkers(file), "a Markdown underline isn't a marker")
    }
}

final class GitHubTests: XCTestCase {
    func testRemoteParsing() {
        let expected = ("github.com", "cricbuzz", "ios-mercury")
        for url in ["git@github.com:cricbuzz/ios-mercury.git", "https://github.com/cricbuzz/ios-mercury.git",
                    "https://github.com/cricbuzz/ios-mercury", "ssh://git@github.com/cricbuzz/ios-mercury.git"] {
            let repo = GitHubRepository(remoteURL: url)
            XCTAssertEqual(repo.map { [$0.host, $0.owner, $0.name] }, [expected.0, expected.1, expected.2], url)
        }
        XCTAssertNil(GitHubRepository(remoteURL: "git@gitlab.com:a/b.git"))
        XCTAssertNil(GitHubRepository(remoteURL: "/local/path"))
        let compare = GitHubRepository(remoteURL: "git@github.com:o/r.git")?.compareURL(base: "develop", head: "mergedesk/a b")
        XCTAssertEqual(compare?.absoluteString,
                       "https://github.com/o/r/compare/develop...mergedesk/a%20b?expand=1")
    }

    func testPullRequestListParsingAndCheckSummary() throws {
        let json = """
        [
          {"number": 1, "title": "A", "url": "https://github.com/o/r/pull/1", "headRefName": "feature/a", "baseRefName": "develop",
           "isDraft": false, "statusCheckRollup": [{"status": "COMPLETED", "conclusion": "SUCCESS"}, {"state": "SUCCESS"}]},
          {"number": 2, "title": "B", "url": "u", "headRefName": "b", "baseRefName": "develop", "isDraft": true,
           "statusCheckRollup": [{"status": "IN_PROGRESS", "conclusion": ""}]},
          {"number": 3, "title": "C", "url": "u", "headRefName": "c", "baseRefName": "main", "isDraft": false,
           "statusCheckRollup": [{"status": "COMPLETED", "conclusion": "FAILURE"}, {"status": "QUEUED"}]},
          {"number": 4, "title": "D", "url": "u", "headRefName": "d", "baseRefName": "main", "isDraft": false, "statusCheckRollup": []}
        ]
        """
        let prs = try GitHubCLI.parsePullRequests(Data(json.utf8))
        XCTAssertEqual(prs.map(\.checks), [.passing, .pending, .failing, .none])
        XCTAssertEqual(prs.first?.headRefName, "feature/a")
        XCTAssertTrue(prs[1].isDraft)
    }
}
