@testable import MergeDeskCore
import MergeDeskFixtures
@testable import MergeDeskUI
import XCTest

/// Every model in these tests uses a throwaway support folder, in-memory preferences and no GitHub CLI —
/// never the user's real Merge Desk data or defaults.

/// The guided Merge tab, end to end on real git.
@MainActor
final class MergeFlowModelTests: XCTestCase {
    private var folder: URL!
    private let git = ProcessGitClient(environmentOverrides: FixtureBuilder.isolatedEnvironment)

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mergedesk-flow-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func model(_ pattern: FixturePattern) async throws -> (RepositoryModel, URL) {
        let fixture = try await FixtureBuilder().build(pattern, in: folder)
        // Fixtures are checked out on the target branch; Apply refuses to move a checked-out branch.
        _ = try await git.run(["switch", "--quiet", FixtureBranch.base], in: fixture.url)
        let model = isolatedRepositoryModel(fixture.url, support: folder.appendingPathComponent("support"), git: git)
        model.refresh()
        await model.waitForRefresh()
        return (model, fixture.url)
    }

    func testChooseMergeResolveCompleteApplyUndo() async throws {
        let (model, root) = try await model(.contentConflict)
        let flow = try XCTUnwrap(model.mergeFlow)
        XCTAssertEqual(flow.step, .choose)
        XCTAssertEqual(flow.mergeBlockedReason, "Choose both branches.")

        flow.into = FixtureBranch.target
        flow.from = FixtureBranch.target
        XCTAssertEqual(flow.mergeBlockedReason, "Choose two different branches.")
        flow.from = FixtureBranch.source
        flow.fetchFirst = false
        await flow.waitForPreview()
        let preview = try XCTUnwrap(flow.preview.value)
        XCTAssertEqual(preview.commitsToBring, 1)
        XCTAssertEqual(preview.prediction?.conflicts.map(\.path), ["Sources/App.swift"])
        XCTAssertNil(flow.mergeBlockedReason)

        await flow.merge()
        XCTAssertEqual(flow.step, .resolveConflicts)
        XCTAssertEqual(flow.session?.conflictedFiles, ["Sources/App.swift"])

        await flow.openResolver("Sources/App.swift")
        XCTAssertEqual(flow.choices.count, 1)
        XCTAssertFalse(flow.canSaveChoices)
        flow.chooseForAll(.into)
        XCTAssertEqual(flow.resolvedPreview, "let timeout = 20\nlet retries = 3\nlet host = \"api\"\n")
        await flow.saveChoices()
        XCTAssertNil(flow.resolvingPath, "the sheet closes")
        XCTAssertEqual(flow.step, .readyToComplete)

        await flow.complete()
        XCTAssertEqual(flow.step, .readyToApply)
        let before = try await git.execute(.commitID(of: FixtureBranch.target), in: root)
        await flow.apply()
        XCTAssertNil(flow.errorMessage)
        XCTAssertEqual(flow.step, .applied)
        await flow.undo()
        XCTAssertEqual(flow.step, .choose, "after undo the tab is ready for a new merge")
        let after = try await git.execute(.commitID(of: FixtureBranch.target), in: root)
        XCTAssertEqual(after, before)
    }

    func testNothingToMergeAndDiscard() async throws {
        let (model, _) = try await model(.cleanMerge)
        let flow = try XCTUnwrap(model.mergeFlow)
        flow.into = FixtureBranch.target
        flow.from = FixtureBranch.base
        await flow.waitForPreview()
        XCTAssertEqual(flow.preview.value?.nothingToMerge, true)
        XCTAssertEqual(flow.mergeBlockedReason, "target already has everything from base.")

        flow.swapBranches()
        XCTAssertEqual(flow.into, FixtureBranch.base)
        flow.from = FixtureBranch.source
        flow.fetchFirst = false
        await flow.waitForPreview()
        XCTAssertEqual(flow.preview.value?.prediction?.isClean, true)
        await flow.merge()
        XCTAssertEqual(flow.step, .readyToApply, "a clean merge needs no resolving")
        await flow.discard()
        XCTAssertEqual(flow.step, .choose)
    }

    func testToolbarMergePrefillsTheSelectedBranch() async throws {
        let (model, _) = try await model(.cleanMerge)
        model.selectedBranch = FixtureBranch.source
        model.startMergeFromSelection()
        XCTAssertEqual(model.contentMode, .merge)
        XCTAssertEqual(model.mergeFlow.from, FixtureBranch.source)
    }
}
