@testable import MergeDeskCore
import MergeDeskFixtures
@testable import MergeDeskUI
import XCTest

/// Every model in these tests uses a throwaway support folder, in-memory preferences and no GitHub CLI —
/// never the user's real Merge Desk data or defaults.
@MainActor
func isolatedRepositoryModel(_ root: URL, support: URL, git: GitClient) -> RepositoryModel {
    RepositoryModel(repository: RegisteredRepository(path: root.path), git: git, paths: SupportPaths(root: support),
                    defaults: MemoryPreferenceStore(), github: GitHubCLI(executableURL: nil))
}

@MainActor
final class RepositoryModelTests: XCTestCase {
    private typealias Branch = InventoryFixture.Branch

    private var folder: URL!
    private var fixture: InventoryFixture!
    private let git = ProcessGitClient(environmentOverrides: FixtureBuilder.isolatedEnvironment)

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mergedesk-ui-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fixture = try await InventoryFixture.build(in: folder)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func loadedModel() async throws -> RepositoryModel {
        let model = isolatedRepositoryModel(fixture.clone, support: folder.appendingPathComponent("support"), git: git)
        model.refresh(now: InventoryFixture.now)
        await model.waitForRefresh()
        XCTAssertNotNil(model.inventory, model.inventoryState.errorMessage ?? "not loaded")
        return model
    }

    func testRefreshLoadsRowsSortedByMostRecentCommit() async throws {
        let model = try await loadedModel()
        XCTAssertEqual(model.rows.count, 7)
        XCTAssertEqual(model.integrationNames, [Branch.develop, Branch.main])
        let dates = model.rows.map(\.lastCommit)
        XCTAssertEqual(dates, dates.sorted(by: >), "default sort: newest first")
        let active = try XCTUnwrap(model.rows.first { $0.name == Branch.active })
        XCTAssertEqual(active.first.text, "↑2 ↓0")
        XCTAssertEqual(active.presenceText, "Both")
        XCTAssertTrue(active.notes.contains(.unpushed(1)))
        let mergedNote = BranchNote.merged(into: [Branch.develop])
        XCTAssertEqual(mergedNote.shortText, "Merged")
        XCTAssertEqual(mergedNote.text, "Merged into develop")
        let merged = try XCTUnwrap(model.rows.first { $0.name == Branch.merged })
        XCTAssertEqual(merged.first.text, "merged")
        XCTAssertEqual(merged.second.text, "↑2 ↓0")
        let develop = try XCTUnwrap(model.rows.first { $0.name == Branch.develop })
        XCTAssertEqual(develop.first.text, BranchRow.missingValue, "integration branches have no comparison")
    }

    func testFilterAndSortUpdateRows() async throws {
        let model = try await loadedModel()
        model.filter.scope = .unpushed
        XCTAssertEqual(Set(model.rows.map(\.name)), [Branch.active, Branch.localOnly])
        model.filter = BranchFilter(searchText: "remote-only")
        XCTAssertEqual(model.rows.map(\.name), [Branch.remoteOnly])
        model.filter = BranchFilter()
        model.sortOrder = [KeyPathComparator(\BranchRow.name)]
        XCTAssertEqual(model.rows.map(\.name), model.rows.map(\.name).sorted())
        model.sortOrder = [KeyPathComparator(\BranchRow.firstSortKey, order: .reverse)]
        XCTAssertEqual(model.rows.first?.first.text, BranchRow.missingValue, "missing comparisons sort as largest")
    }

    func testSelectingABranchLoadsItsDetail() async throws {
        let model = try await loadedModel()
        model.selectedBranch = Branch.active
        XCTAssertTrue(model.detailState.isLoading)
        await model.waitForDetail()
        let detail = try XCTUnwrap(model.detailState.value)
        XCTAssertEqual(detail.branch.name, Branch.active)
        XCTAssertEqual(detail.overlaps.map(\.branch), [Branch.remoteOnly])

        model.selectedBranch = nil
        XCTAssertNil(model.detailState.value, "clearing the selection clears the detail")
    }

    func testSelectionSurvivesRefreshAndIsDroppedWhenTheBranchDisappears() async throws {
        let model = try await loadedModel()
        model.selectedBranch = Branch.localOnly
        await model.waitForDetail()

        model.refresh(now: InventoryFixture.now)
        await model.waitForRefresh()
        XCTAssertEqual(model.selectedBranch, Branch.localOnly)

        _ = try await git.run(["switch", "--quiet", Branch.main], in: fixture.clone)
        _ = try await git.run(["branch", "--quiet", "-D", Branch.localOnly], in: fixture.clone)
        model.refresh(now: InventoryFixture.now)
        await model.waitForRefresh()
        XCTAssertNil(model.selectedBranch)
        XCTAssertEqual(model.rows.count, 6)
    }

    private func isolatedModel(_ root: URL) -> RepositoryModel {
        isolatedRepositoryModel(root, support: folder.appendingPathComponent("support"), git: git)
    }

    func testPredictionsFillTheMergeColumnAndWillConflictFilter() async throws {
        let model = isolatedModel(fixture.clone)
        model.refresh(now: InventoryFixture.now)
        await model.waitForRefresh()
        XCTAssertNotNil(model.predictions, model.predictionState.errorMessage ?? "")
        let active = try XCTUnwrap(model.rows.first { $0.name == Branch.active })
        XCTAssertEqual(active.merge.text, "clean")
        XCTAssertEqual(model.rows.first { $0.name == Branch.merged }?.merge.text, "merged")
        XCTAssertEqual(model.rows.first { $0.name == Branch.develop }?.merge.text, BranchRow.missingValue)
        model.filter.scope = .willConflict
        XCTAssertEqual(model.rows, [], "nothing conflicts with develop in this fixture")
    }

    func testWillConflictWithARealConflict() async throws {
        let conflict = try await FixtureBuilder().build(.contentConflict, in: folder)
        var config = RepoConfig.defaults
        config.integrationBranches = [conflict.definition.targetBranch]
        config.staleDays = 3650
        try JSONEncoder().encode(config).write(to: conflict.url.appendingPathComponent(MergeDeskConstants.configFileName))
        let model = isolatedModel(conflict.url)
        model.refresh()
        await model.waitForRefresh()
        model.filter.scope = .willConflict
        XCTAssertEqual(model.rows.map(\.name), [conflict.definition.sourceBranch])
        XCTAssertEqual(model.rows.first?.merge.text, "1 file")
        model.selectedBranch = conflict.definition.sourceBranch
        XCTAssertEqual(model.selectedBranchPredictions.first?.prediction.prediction?.conflicts.map(\.path), ["Sources/App.swift"])
    }

    func testMatrixLoadsWhenShown() async throws {
        let model = isolatedModel(fixture.clone)
        model.refresh(now: InventoryFixture.now)
        await model.waitForRefresh()
        XCTAssertNil(model.matrixState.value, "the matrix is computed only when shown")
        model.contentMode = .matrix
        await model.waitForMatrix()
        let matrix = try XCTUnwrap(model.matrixState.value?.matrix)
        XCTAssertEqual(matrix.conflictingPairs.map { "\($0.first) ↔ \($0.second)" }, ["\(Branch.active) ↔ \(Branch.remoteOnly)"])
    }

    func testRunDailyWritesADigestAndReloads() async throws {
        let model = isolatedModel(fixture.clone)
        XCTAssertNil(model.digest)
        model.refresh(now: InventoryFixture.now)
        await model.waitForRefresh()
        model.runDaily(fetch: true, now: InventoryFixture.now)
        XCTAssertTrue(model.isRunningDaily)
        await model.waitForDaily()
        XCTAssertFalse(model.isRunningDaily)
        XCTAssertNil(model.dailyError)
        XCTAssertEqual(model.digest?.fetch, .fetched)
        XCTAssertEqual(model.digest?.pairConflicts.count, 1)
        XCTAssertNotNil(model.inventory)

        let reopened = isolatedModel(fixture.clone)
        XCTAssertEqual(reopened.digest, model.digest, "the digest is read back from the support folder")
    }

    func testNonRepositoryShowsAnError() async throws {
        let plain = folder.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let model = isolatedRepositoryModel(plain, support: folder.appendingPathComponent("support"), git: git)
        model.refresh()
        XCTAssertTrue(model.inventoryState.isLoading, "first load shows the spinner")
        await model.waitForRefresh()
        XCTAssertNotNil(model.inventoryState.errorMessage)
        XCTAssertEqual(model.rows, [])
    }

    func testInvalidConfigShowsItsMessage() async throws {
        try Data(#"{ "staleDays": 0 }"#.utf8).write(to: fixture.clone.appendingPathComponent(MergeDeskConstants.configFileName))
        let model = isolatedRepositoryModel(fixture.clone, support: folder.appendingPathComponent("support"), git: git)
        model.refresh()
        await model.waitForRefresh()
        XCTAssertTrue(model.inventoryState.errorMessage?.contains("staleDays") ?? false, model.inventoryState.errorMessage ?? "")
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mergedesk-app-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeApp() -> AppModel {
        AppModel(paths: SupportPaths(root: folder.appendingPathComponent("support")),
                 git: ProcessGitClient(environmentOverrides: FixtureBuilder.isolatedEnvironment))
    }

    func testAddSelectPersistAndRemove() async throws {
        let repository = try await FixtureBuilder().build(.cleanMerge, in: folder)
        let subfolder = repository.url.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

        let app = makeApp()
        XCTAssertEqual(app.repositories, [])
        await app.addRepository(at: subfolder)
        XCTAssertNil(app.alertMessage)
        XCTAssertEqual(app.repositories.map(\.path), [repository.url.standardizedFileURL.path], "stored as the repository root")
        XCTAssertEqual(app.selectedRepositoryID, app.repositories.first?.id)
        XCTAssertNotNil(app.selectedModel)

        await app.addRepository(at: repository.url)
        XCTAssertTrue(app.alertMessage?.contains("already") ?? false)
        app.alertMessage = nil

        let reopened = makeApp()
        XCTAssertEqual(reopened.repositories, app.repositories, "the list survives a restart")
        XCTAssertEqual(reopened.selectedRepositoryID, app.repositories.first?.id)

        let id = try XCTUnwrap(app.repositories.first?.id)
        app.removeRepository(id)
        XCTAssertEqual(app.repositories, [])
        XCTAssertNil(app.selectedRepositoryID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.url.path), "removing never touches the folder")
    }

    func testAddingANonRepositoryAlerts() async throws {
        let app = makeApp()
        await app.addRepository(at: folder)
        XCTAssertTrue(app.alertMessage?.contains("not inside a git repository") ?? false, app.alertMessage ?? "")
        XCTAssertEqual(app.repositories, [])
    }

    func testModelsArePerRepositoryAndReused() async throws {
        let first = try await FixtureBuilder().build(.cleanMerge, in: folder)
        let second = try await FixtureBuilder().build(.contentConflict, in: folder)
        let app = makeApp()
        await app.addRepository(at: first.url)
        await app.addRepository(at: second.url)
        let firstID = try XCTUnwrap(app.repositories.first?.id)
        let model = try XCTUnwrap(app.selectedModel)
        app.selectedRepositoryID = firstID
        app.selectedRepositoryID = app.repositories.last?.id
        XCTAssertTrue(app.selectedModel === model, "switching back keeps the same model (filters, selection)")
    }
}

@MainActor
final class SessionsModelTests: XCTestCase {
    private var folder: URL!
    private let git = ProcessGitClient(environmentOverrides: FixtureBuilder.isolatedEnvironment)

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mergedesk-sessions-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testMergeApplyUndoThroughTheModel() async throws {
        let fixture = try await FixtureBuilder().build(.cleanMerge, in: folder)
        let model = isolatedRepositoryModel(fixture.url, support: folder.appendingPathComponent("support"), git: git)
        model.refresh()
        await model.waitForRefresh()
        let sessions = model.sessions

        let preview = await sessions.preview(source: FixtureBranch.source, target: FixtureBranch.target,
                                             inventory: try XCTUnwrap(model.inventory))
        XCTAssertEqual(preview?.isClean, true)

        await sessions.startMerge(source: FixtureBranch.source, target: FixtureBranch.target, strategy: .mergeCommit, fetch: false)
        let session = try XCTUnwrap(sessions.selected)
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(SessionAction.available(for: session), [.apply, .abort])
        XCTAssertEqual(sessions.openCount, 1)

        await sessions.run(.apply, on: session)
        XCTAssertTrue(sessions.errorMessage?.contains("checked out") ?? false, "the fixture is on the target branch")
        _ = try await git.run(["switch", "--quiet", FixtureBranch.base], in: fixture.url)

        await sessions.run(.apply, on: session)
        XCTAssertNil(sessions.errorMessage)
        let applied = try XCTUnwrap(sessions.selected)
        XCTAssertEqual(applied.state, .applied)
        XCTAssertEqual(SessionAction.available(for: applied), [.push, .undo])
        XCTAssertTrue(SessionAction.push.needsConfirmation)

        await sessions.run(.push, on: applied, confirmed: false)
        XCTAssertTrue(sessions.errorMessage?.contains("confirmation") ?? false)

        await sessions.run(.undo, on: applied)
        XCTAssertEqual(sessions.selected?.state, .undone)
        XCTAssertEqual(sessions.openCount, 0)
        await model.waitForRefresh()
        let target = try await git.execute(.commitID(of: FixtureBranch.target), in: fixture.url)
        XCTAssertEqual(target, applied.targetLocalID)
    }

    func testPullRequestNoteComesFirst() throws {
        let fixtureBranch = BranchRecord(name: "feature/x", local: nil, remotes: [], tip: GitRef(
            fullName: "refs/remotes/origin/feature/x", kind: .remote(name: "origin"), branchName: "feature/x",
            objectID: String(repeating: "a", count: 40), committerDate: Date(), authorName: "A", authorEmail: "a@x", upstream: nil),
            isIntegration: false, isProtected: false, isActiveWork: true, isStale: true, localSync: nil, integration: [])
        let pullRequest = PullRequestInfo(number: 42, title: "T", url: "u", headRefName: "feature/x", baseRefName: "develop",
                                 isDraft: false, checks: .failing)
        let row = BranchRow(fixtureBranch, integrationNames: [], pullRequest: pullRequest)
        XCTAssertEqual(row.notes.first, .pullRequest(number: 42, checks: .failing))
        XCTAssertEqual(row.notes.first?.text, "PR #42 ✗")
    }
}

final class ScheduleModelTests: XCTestCase {
    @MainActor
    func testEnableDisableWithoutLaunchd() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mergedesk-schedule-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let schedule = DailySchedule(launchAgentsFolder: folder, paths: SupportPaths(root: folder), usesLaunchctl: false)
        let model = ScheduleModel(schedule: schedule, executablePath: "/Applications/MergeDesk.app/Contents/MacOS/MergeDesk")
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.time, .defaultDailyRun)
        model.time = try XCTUnwrap(DailyTime("08:15"))
        await model.enable()
        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(model.installed?.programArguments,
                       ["/Applications/MergeDesk.app/Contents/MacOS/MergeDesk", ScheduleModel.dailyArgument])
        XCTAssertFalse(model.pointsElsewhere)
        let moved = ScheduleModel(schedule: schedule, executablePath: "/elsewhere/MergeDesk")
        XCTAssertTrue(moved.pointsElsewhere)
        XCTAssertEqual(moved.time.description, "08:15", "the picker shows the installed time")
        await model.disable()
        XCTAssertFalse(model.isEnabled)
        XCTAssertNil(model.errorMessage)
    }
}

final class AgeAndRowTests: XCTestCase {
    func testAgeFormatting() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(TimeInterval, String)] = [
            (-60, "now"), (59 * 60, "now"), (2 * 3600, "2h"), (3 * 86_400, "3d"), (20 * 86_400, "2w"),
            (100 * 86_400, "3mo"), (800 * 86_400, "2y"),
        ]
        for (age, text) in cases {
            XCTAssertEqual(AgeFormatting.short(from: now.addingTimeInterval(-age), to: now), text, "\(age)")
        }
    }
}
