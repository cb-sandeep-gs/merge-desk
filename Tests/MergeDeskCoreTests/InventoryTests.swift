import XCTest
@testable import MergeDeskCore
@testable import MergeDeskFixtures

/// The inventory against a real origin + clone (see `InventoryFixture` for the timeline).
final class InventoryTests: XCTestCase {
    private typealias Branch = InventoryFixture.Branch

    // Written once in `setUp()` before any test runs, then only read: safe without isolation.
    nonisolated(unsafe) private static var folder: URL!
    nonisolated(unsafe) private static var fixture: InventoryFixture!
    nonisolated(unsafe) private static var inventory: RepositoryInventory!

    private let git = ProcessGitClient(environmentOverrides: FixtureBuilder.isolatedEnvironment)

    /// One fixture for the whole class: building it is the slow part, and every test only reads it.
    override static func setUp() {
        super.setUp()
        let done = XCTestExpectation(description: "fixture")
        Task {
            do {
                folder = try TemporaryFolder.make()
                fixture = try await InventoryFixture.build(in: folder)
                let git = ProcessGitClient(environmentOverrides: FixtureBuilder.isolatedEnvironment)
                inventory = try await InventoryBuilder(git: git).build(
                    repositoryRoot: fixture.clone, config: .defaults, now: InventoryFixture.now
                )
            } catch {
                XCTFail("fixture failed: \(error)")
            }
            done.fulfill()
        }
        _ = XCTWaiter.wait(for: [done], timeout: 60)
    }

    override static func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    private func branch(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> BranchRecord {
        try XCTUnwrap(Self.inventory.branch(named: name), "missing \(name)", file: file, line: line)
    }

    // MARK: inventory

    func testEveryBranchAppearsOnceWithItsPresence() throws {
        let expected: [String: BranchPresence] = [
            Branch.main: .both, Branch.develop: .both, Branch.merged: .remote, Branch.stale: .remote,
            Branch.active: .both, Branch.remoteOnly: .remote, Branch.localOnly: .local,
        ]
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: Self.inventory.branches.map { ($0.name, $0.presence) }), expected)
        XCTAssertEqual(Self.inventory.branches.map(\.name), Self.inventory.branches.map(\.name).sorted(), "sorted by name")
        XCTAssertEqual(Self.inventory.integrationRefs.map(\.name), [Branch.develop, Branch.main])
        XCTAssertEqual(Self.inventory.integrationRefs.map(\.ref), ["refs/remotes/origin/develop", "refs/remotes/origin/main"])
        XCTAssertEqual(Self.inventory.missingIntegrationBranches, [])
        XCTAssertEqual(Self.inventory.currentUserEmail, InventoryFixture.developerEmail)
    }

    func testComparisonsUseTheRemoteTipAndFlagUnpushedWork() throws {
        let active = try branch(Branch.active)
        XCTAssertEqual(active.tip.kind, .remote(name: "origin"), "the team's copy is what gets compared")
        XCTAssertEqual(active.status(against: Branch.develop)?.aheadBehind, AheadBehind(ahead: 2, behind: 0))
        XCTAssertEqual(active.localSync, AheadBehind(ahead: 1, behind: 0), "one unpushed local commit")
        XCTAssertTrue(active.hasUnpushedCommits)

        let develop = try branch(Branch.develop)
        XCTAssertEqual(develop.localSync, AheadBehind(ahead: 0, behind: 0), "in-sync copies read 0/0")
        XCTAssertTrue(develop.isIntegration)
        XCTAssertEqual(develop.integration, [], "integration branches aren't compared with themselves")

        let localOnly = try branch(Branch.localOnly)
        XCTAssertEqual(localOnly.tip.kind, .local)
        XCTAssertNil(localOnly.localSync)
        XCTAssertTrue(localOnly.hasUnpushedCommits)
        XCTAssertFalse(try branch(Branch.remoteOnly).hasUnpushedCommits)
    }

    func testAheadBehindMergedAndStale() throws {
        let merged = try branch(Branch.merged)
        XCTAssertEqual(merged.status(against: Branch.develop)?.aheadBehind, AheadBehind(ahead: 0, behind: 0))
        XCTAssertEqual(merged.status(against: Branch.main)?.aheadBehind, AheadBehind(ahead: 2, behind: 0))
        XCTAssertEqual(merged.mergedInto, [Branch.develop])
        XCTAssertTrue(merged.isStale)

        let stale = try branch(Branch.stale)
        XCTAssertEqual(stale.status(against: Branch.develop)?.aheadBehind, AheadBehind(ahead: 1, behind: 2))
        XCTAssertEqual(stale.status(against: Branch.main)?.aheadBehind, AheadBehind(ahead: 1, behind: 0))
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.mergedInto, [])

        XCTAssertFalse(try branch(Branch.active).isStale)
        XCTAssertTrue(try branch(Branch.main).isProtected)
        XCTAssertFalse(try branch(Branch.active).isProtected)
    }

    /// Every number must equal what plain git reports — the MD-1 "matches git" gate, on the fixture.
    func testNumbersMatchPlainGit() async throws {
        for record in Self.inventory.branches where !record.isIntegration {
            for status in record.integration {
                let base = try XCTUnwrap(Self.inventory.integrationRefs.first { $0.name == status.integration })
                let result = try await git.run(["rev-list", "--left-right", "--count", "\(base.ref)...\(record.tip.fullName)"],
                                               in: Self.fixture.clone)
                let parts = String(decoding: result.standardOutput, as: UTF8.self).split(whereSeparator: \.isWhitespace)
                XCTAssertEqual(parts.map { Int($0) }, [status.aheadBehind.behind, status.aheadBehind.ahead],
                               "\(record.name) vs \(status.integration)")
            }
        }
    }

    func testRebuildIsIdenticalAndUsesTheCache() async throws {
        let cache = ComparisonCache()
        let builder = InventoryBuilder(git: git, cache: cache)
        let first = try await builder.build(repositoryRoot: Self.fixture.clone, config: .defaults, now: InventoryFixture.now)
        let second = try await builder.build(repositoryRoot: Self.fixture.clone, config: .defaults, now: InventoryFixture.now)
        XCTAssertEqual(first, Self.inventory)
        XCTAssertEqual(second, first)
        let develop = try XCTUnwrap(first.integrationRefs.first)
        let cached = await cache.aheadBehind(tip: try branch(Branch.stale).tip.objectID, base: develop.objectID)
        XCTAssertEqual(cached, AheadBehind(ahead: 1, behind: 2))
    }

    func testMissingIntegrationBranchIsReportedNotFatal() async throws {
        var config = RepoConfig.defaults
        config.integrationBranches = ["develop", "release/next"]
        let inventory = try await InventoryBuilder(git: git).build(repositoryRoot: Self.fixture.clone, config: config,
                                                                    now: InventoryFixture.now)
        XCTAssertEqual(inventory.missingIntegrationBranches, ["release/next"])
        XCTAssertEqual(inventory.integrationRefs.map(\.name), ["develop"])
        XCTAssertFalse(try XCTUnwrap(inventory.branch(named: Branch.main)).isIntegration, "main isn't integration in this config")
    }

    func testInventoryIsCodableForJSONOutput() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RepositoryInventory.self, from: encoder.encode(Self.inventory))
        XCTAssertEqual(decoded.branches.map(\.name), Self.inventory.branches.map(\.name))
        XCTAssertEqual(decoded.branches.map(\.integration), Self.inventory.branches.map(\.integration))
    }

    // MARK: filters

    private func names(_ filter: BranchFilter) -> [String] {
        filter.apply(to: Self.inventory).map(\.name)
    }

    func testFilterScopes() {
        XCTAssertEqual(names(BranchFilter(scope: .all)).count, 7)
        XCTAssertEqual(Set(names(BranchFilter(scope: .mine))), Set(Self.inventory.branches.map(\.name)).subtracting([Branch.remoteOnly]))
        XCTAssertEqual(names(BranchFilter(scope: .active)), [Branch.active, Branch.localOnly, Branch.remoteOnly])
        XCTAssertEqual(names(BranchFilter(scope: .stale)), [Branch.merged, Branch.stale], "integration branches never show as stale")
        XCTAssertEqual(names(BranchFilter(scope: .merged)), [Branch.merged])
        XCTAssertEqual(names(BranchFilter(scope: .unpushed)), [Branch.active, Branch.localOnly])
    }

    func testSearchAndPrefix() {
        XCTAssertEqual(names(BranchFilter(searchText: "LOCAL")), [Branch.localOnly])
        XCTAssertEqual(names(BranchFilter(searchText: "other dev")), [Branch.remoteOnly], "search also matches the author")
        XCTAssertEqual(names(BranchFilter(prefix: "feature/")).count, 5)
        XCTAssertEqual(BranchFilter.prefixes(in: Self.inventory.branches), ["feature/"])
    }

    // MARK: detail

    func testDetailListsCommitsFilesAndOverlaps() async throws {
        let detail = try await BranchDetailLoader(git: git).load(branchNamed: Branch.active, from: Self.inventory,
                                                                 repositoryRoot: Self.fixture.clone)
        XCTAssertEqual(detail.base?.name, Branch.develop)
        XCTAssertEqual(detail.uniqueCommits.map(\.subject), ["feat: active two", "feat: active one"], "newest first, remote tip")
        XCTAssertFalse(detail.uniqueCommitsTruncated)
        XCTAssertEqual(detail.changedFiles, ["active.txt", "active2.txt", "shared.txt"])
        XCTAssertEqual(detail.overlaps, [BranchOverlap(branch: Branch.remoteOnly, sharedFiles: ["shared.txt"])])
    }

    func testDetailTruncatesLongHistories() async throws {
        let detail = try await BranchDetailLoader(git: git).load(branchNamed: Branch.active, from: Self.inventory,
                                                                 repositoryRoot: Self.fixture.clone, maxCommits: 1)
        XCTAssertEqual(detail.uniqueCommits.count, 1)
        XCTAssertTrue(detail.uniqueCommitsTruncated)
    }

    func testDetailOfIntegrationBranchUsesTheNextOne() async throws {
        let detail = try await BranchDetailLoader(git: git).load(branchNamed: Branch.develop, from: Self.inventory,
                                                                 repositoryRoot: Self.fixture.clone)
        XCTAssertEqual(detail.base?.name, Branch.main)
        XCTAssertEqual(detail.uniqueCommits.count, 2)
    }

    func testDetailOfUnknownBranchThrows() async {
        do {
            _ = try await BranchDetailLoader(git: git).load(branchNamed: "nope", from: Self.inventory, repositoryRoot: Self.fixture.clone)
            XCTFail("expected unknownBranch")
        } catch {
            XCTAssertEqual(error as? BranchDetailError, .unknownBranch("nope"))
        }
    }
}

final class BoundedConcurrencyTests: XCTestCase {
    /// Order is kept and the limit is never exceeded.
    func testKeepsOrderAndRespectsTheLimit() async throws {
        let counter = InFlightCounter()
        let output = try await boundedConcurrentMap(Array(0..<40), limit: 3) { value -> Int in
            await counter.enter()
            try await Task.sleep(nanoseconds: 2_000_000)
            await counter.leave()
            return value * 2
        }
        XCTAssertEqual(output, (0..<40).map { $0 * 2 })
        let peak = await counter.peak
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertGreaterThan(peak, 1, "work actually runs in parallel")
    }

    func testEmptyInput() async throws {
        let output = try await boundedConcurrentMap([Int](), limit: 4) { $0 }
        XCTAssertEqual(output, [])
    }
}

private actor InFlightCounter {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() { current -= 1 }
}
