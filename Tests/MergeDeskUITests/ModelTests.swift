import MergeDeskCore
import MergeDeskFixtures
@testable import MergeDeskUI
import XCTest

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
        let model = RepositoryModel(repository: RegisteredRepository(path: fixture.clone.path), git: git)
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

    func testNonRepositoryShowsAnError() async throws {
        let plain = folder.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let model = RepositoryModel(repository: RegisteredRepository(path: plain.path), git: git)
        model.refresh()
        XCTAssertTrue(model.inventoryState.isLoading, "first load shows the spinner")
        await model.waitForRefresh()
        XCTAssertNotNil(model.inventoryState.errorMessage)
        XCTAssertEqual(model.rows, [])
    }

    func testInvalidConfigShowsItsMessage() async throws {
        try Data(#"{ "staleDays": 0 }"#.utf8).write(to: fixture.clone.appendingPathComponent(MergeDeskConstants.configFileName))
        let model = RepositoryModel(repository: RegisteredRepository(path: fixture.clone.path), git: git)
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

    private func registry() -> RepositoryRegistry {
        RepositoryRegistry(paths: SupportPaths(root: folder.appendingPathComponent("support")),
                           git: ProcessGitClient(environmentOverrides: FixtureBuilder.isolatedEnvironment))
    }

    func testAddSelectPersistAndRemove() async throws {
        let repository = try await FixtureBuilder().build(.cleanMerge, in: folder)
        let subfolder = repository.url.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

        let app = AppModel(registry: registry())
        XCTAssertEqual(app.repositories, [])
        await app.addRepository(at: subfolder)
        XCTAssertNil(app.alertMessage)
        XCTAssertEqual(app.repositories.map(\.path), [repository.url.standardizedFileURL.path], "stored as the repository root")
        XCTAssertEqual(app.selectedRepositoryID, app.repositories.first?.id)
        XCTAssertNotNil(app.selectedModel)

        await app.addRepository(at: repository.url)
        XCTAssertTrue(app.alertMessage?.contains("already") ?? false)
        app.alertMessage = nil

        let reopened = AppModel(registry: registry())
        XCTAssertEqual(reopened.repositories, app.repositories, "the list survives a restart")
        XCTAssertEqual(reopened.selectedRepositoryID, app.repositories.first?.id)

        let id = try XCTUnwrap(app.repositories.first?.id)
        app.removeRepository(id)
        XCTAssertEqual(app.repositories, [])
        XCTAssertNil(app.selectedRepositoryID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.url.path), "removing never touches the folder")
    }

    func testAddingANonRepositoryAlerts() async throws {
        let app = AppModel(registry: registry())
        await app.addRepository(at: folder)
        XCTAssertTrue(app.alertMessage?.contains("not inside a git repository") ?? false, app.alertMessage ?? "")
        XCTAssertEqual(app.repositories, [])
    }

    func testModelsArePerRepositoryAndReused() async throws {
        let first = try await FixtureBuilder().build(.cleanMerge, in: folder)
        let second = try await FixtureBuilder().build(.contentConflict, in: folder)
        let app = AppModel(registry: registry())
        await app.addRepository(at: first.url)
        await app.addRepository(at: second.url)
        let firstID = try XCTUnwrap(app.repositories.first?.id)
        let model = try XCTUnwrap(app.selectedModel)
        app.selectedRepositoryID = firstID
        app.selectedRepositoryID = app.repositories.last?.id
        XCTAssertTrue(app.selectedModel === model, "switching back keeps the same model (filters, selection)")
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
