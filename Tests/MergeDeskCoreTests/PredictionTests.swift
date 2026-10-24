import XCTest
@testable import MergeDeskCore
@testable import MergeDeskFixtures

final class PredictionTests: XCTestCase {
    private typealias Branch = InventoryFixture.Branch

    private var folder: URL!
    private let git = ProcessGitClient(environmentOverrides: FixtureBuilder.isolatedEnvironment)

    override func setUpWithError() throws { folder = try TemporaryFolder.make() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// Config treating the fixture's `target` branch as the only integration branch.
    private func targetConfig(_ fixture: FixtureDefinition, fileClasses: [FileClassRule] = [], regenerate: [String]? = nil) -> RepoConfig {
        var config = RepoConfig.defaults
        config.integrationBranches = [fixture.targetBranch]
        config.protectedBranches = []
        config.fileClasses = fileClasses
        config.regenerateCommand = regenerate
        config.staleDays = 3650
        return config
    }

    private func predict(_ pattern: FixturePattern, config: ((FixtureDefinition) -> RepoConfig)? = nil,
                         store: PredictionStore = PredictionStore(fileURL: nil)) async throws -> (PredictionReport, FixtureRepository) {
        let fixture = try await FixtureBuilder().build(pattern, in: folder)
        let repoConfig = config?(fixture.definition) ?? targetConfig(fixture.definition)
        let inventory = try await InventoryBuilder(git: git).build(repositoryRoot: fixture.url, config: repoConfig)
        let report = try await Predictor(git: git, store: store).predict(
            inventory: inventory, config: repoConfig, repositoryRoot: fixture.url, scope: .integration)
        return (report, fixture)
    }

    /// The accuracy gate: for every fixture, the predicted conflicts equal what a real `git merge` produces.
    func testPredictionsMatchRealMergesOnEveryFixture() async throws {
        for pattern in FixturePattern.allCases {
            let (report, fixture) = try await predict(pattern)
            let definition = fixture.definition
            let predicted = report.integration(named: definition.targetBranch)?.prediction(for: definition.sourceBranch)
            let predictedPaths = predicted?.prediction?.conflicts.map(\.path).sorted() ?? []

            // Real merge in the fixture's own checkout (it is on the target branch).
            _ = try await git.run(["merge", "--no-commit", "--no-ff", definition.sourceBranch], in: fixture.url)
            let status = try await git.execute(.status, in: fixture.url)
            let realPaths = status.entries.filter { $0.kind == .unmerged }.map(\.path).sorted()
            _ = try await git.run(["merge", "--abort"], in: fixture.url)

            XCTAssertEqual(predictedPaths, realPaths, pattern.rawValue)
            XCTAssertEqual(predictedPaths, definition.expectedConflicts.sorted(), pattern.rawValue)
        }
    }

    func testRoutesComeFromFileClasses() async throws {
        let (report, fixture) = try await predict(.generatedFile) { definition in
            self.targetConfig(definition, fileClasses: [FileClassRule(glob: GlobPattern(staticPattern: "**/*.generated.swift"),
                                                                      strategy: .regenerate)],
                              regenerate: ["true"])
        }
        let prediction = try XCTUnwrap(report.integration.first?.prediction(for: fixture.definition.sourceBranch)?.prediction)
        XCTAssertEqual(prediction.conflicts.map(\.route), [.rule(.regenerate)])
        XCTAssertEqual(prediction.automaticCount, 1)
        XCTAssertEqual(prediction.summary, "1 conflict (1 automatic)")
        XCTAssertEqual(prediction.conflicts.first?.kinds, ["CONFLICT (contents)"])

        let (plain, plainFixture) = try await predict(.modifyDelete)
        let manual = try XCTUnwrap(plain.integration.first?.prediction(for: plainFixture.definition.sourceBranch)?.prediction)
        XCTAssertEqual(manual.conflicts.map(\.route), [.historyOrPerson])
        XCTAssertEqual(manual.conflicts.first?.kinds, ["CONFLICT (modify/delete)"])
        XCTAssertEqual(manual.manualCount, 1)
    }

    func testCacheIsReusedAndPersisted() async throws {
        let cacheURL = folder.appendingPathComponent("cache/\(PredictionStore.fileName)")
        let (first, fixture) = try await predict(.contentConflict, store: PredictionStore(fileURL: cacheURL))
        XCTAssertGreaterThan(first.stats.mergesComputed, 0)
        XCTAssertEqual(first.stats.mergesFromCache, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        // A new store reading the same file: everything comes from disk.
        let config = targetConfig(fixture.definition)
        let inventory = try await InventoryBuilder(git: git).build(repositoryRoot: fixture.url, config: config)
        let second = try await Predictor(git: git, store: PredictionStore(fileURL: cacheURL)).predict(
            inventory: inventory, config: config, repositoryRoot: fixture.url, scope: .integration)
        XCTAssertEqual(second.stats.mergesComputed, 0)
        XCTAssertEqual(second.stats.mergesFromCache, first.stats.mergesComputed)
        XCTAssertEqual(second.integration, first.integration)
    }

    func testCorruptCacheFileIsIgnored() async throws {
        let cacheURL = folder.appendingPathComponent(PredictionStore.fileName)
        try Data("not json".utf8).write(to: cacheURL)
        let store = PredictionStore(fileURL: cacheURL)
        let count = await store.count
        XCTAssertEqual(count, 0)
    }

    /// Matrix on the origin + clone fixture: active and remote-only both add `shared.txt` differently.
    func testMatrixFindsConflictingActiveBranches() async throws {
        let fixture = try await InventoryFixture.build(in: folder)
        let inventory = try await InventoryBuilder(git: git).build(repositoryRoot: fixture.clone, config: .defaults,
                                                                    now: InventoryFixture.now)
        let report = try await Predictor(git: git).predict(inventory: inventory, config: .defaults,
                                                            repositoryRoot: fixture.clone, scope: .integrationAndMatrix,
                                                            now: InventoryFixture.now)
        let matrix = try XCTUnwrap(report.matrix)
        XCTAssertEqual(Set(matrix.branches), [Branch.active, Branch.remoteOnly, Branch.localOnly],
                       "stale and merged branches stay out of the matrix")
        XCTAssertEqual(matrix.conflictingPairs.map(\.id), [PairPrediction(first: Branch.active, second: Branch.remoteOnly,
                                                                          prediction: matrix.conflictingPairs[0].prediction).id])
        XCTAssertEqual(matrix.pair(Branch.remoteOnly, Branch.active)?.prediction.conflicts.map(\.path), ["shared.txt"])
        XCTAssertNil(matrix.pair(Branch.active, Branch.localOnly), "clean pairs aren't listed")
        XCTAssertEqual(matrix.omittedBranches, [])

        let develop = try XCTUnwrap(report.integration(named: Branch.develop))
        XCTAssertTrue(develop.prediction(for: Branch.merged)?.isAlreadyMerged ?? false)
        XCTAssertEqual(develop.conflicting.map(\.branch), [], "nothing conflicts with develop in this fixture")
        XCTAssertNil(develop.prediction(for: Branch.develop), "integration branches aren't predicted into themselves")
    }
}

final class DailyRunTests: XCTestCase {
    private typealias Branch = InventoryFixture.Branch

    private var folder: URL!
    private let git = ProcessGitClient(environmentOverrides: FixtureBuilder.isolatedEnvironment)

    override func setUpWithError() throws { folder = try TemporaryFolder.make() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testFirstRunThenNewConflictAfterFetch() async throws {
        let fixture = try await InventoryFixture.build(in: folder)
        let paths = SupportPaths(root: folder.appendingPathComponent("support"))
        let notifier = RecordingNotifier()
        let runner = DailyRunner(git: git, paths: paths, notifier: notifier)

        let first = try await runner.run(repositoryRoot: fixture.clone, fetch: true, now: InventoryFixture.now)
        XCTAssertEqual(first.digest.fetch, .fetched)
        XCTAssertFalse(first.digest.hasPreviousRun)
        XCTAssertEqual(first.digest.newConflicts, [], "first run has nothing to compare with")
        XCTAssertEqual(first.digest.pairConflicts.map(\.key.description), ["\(Branch.active) ↔ \(Branch.remoteOnly)"])
        XCTAssertEqual(first.digest.mergedNotDeleted, [Branch.merged])
        XCTAssertEqual(first.digest.stale.map(\.branch), [Branch.stale])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.markdownURL.path))
        XCTAssertEqual(DailyRunner.latestDigest(repositoryRoot: fixture.clone, paths: paths), first.digest)
        let firstNotifications = await notifier.messages
        XCTAssertEqual(firstNotifications.count, 0, "a quiet day stays quiet")

        // A teammate pushes a branch that also adds shared.txt (dated on the fixture's recent day).
        let recent = "\(Int(InventoryFixture.now.timeIntervalSince1970) - 3_600) +0000"
        var clock = FixtureClock()
        try await FixtureBuilder().play([.switchTo(Branch.develop), .createBranch("feature/new"),
                                         .write("shared.txt", "from new\n")], in: fixture.origin, clock: &clock)
        _ = try await git.run(["add", "--all"], in: fixture.origin)
        _ = try await git.run(["commit", "--quiet", "-m", "feat: new"], in: fixture.origin,
                              environment: ["GIT_AUTHOR_DATE": recent, "GIT_COMMITTER_DATE": recent])

        let second = try await runner.run(repositoryRoot: fixture.clone, fetch: true, now: InventoryFixture.now)
        XCTAssertTrue(second.digest.hasPreviousRun)
        XCTAssertEqual(second.digest.newConflicts.map(\.key.description).sorted(),
                       ["\(Branch.active) ↔ feature/new", "feature/new ↔ \(Branch.remoteOnly)"])
        XCTAssertEqual(second.digest.resolvedConflicts, [])
        let notifications = await notifier.messages
        XCTAssertEqual(notifications.count, 1)
        XCTAssertTrue(notifications.first?.body.contains("2 new conflicts") ?? false, notifications.first?.body ?? "")

        let markdown = try String(contentsOf: second.markdownURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("## New conflicts since last run"))
        XCTAssertTrue(markdown.contains("feature/new"))
    }

    func testFetchFailureIsReportedNotThrown() async throws {
        let fixture = try await InventoryFixture.build(in: folder)
        _ = try await git.run(["remote", "set-url", "origin", folder.appendingPathComponent("missing").path], in: fixture.clone)
        let runner = DailyRunner(git: git, paths: SupportPaths(root: folder.appendingPathComponent("support")),
                                 notifier: SilentNotifier())
        let result = try await runner.run(repositoryRoot: fixture.clone, fetch: true, now: InventoryFixture.now)
        guard case .failed = result.digest.fetch else { return XCTFail("expected a failed fetch, got \(result.digest.fetch)") }
        XCTAssertFalse(result.digest.pairConflicts.isEmpty, "the run still reports from the last fetched state")
    }

    func testRebaseTodayListsTheUsersConflictingBranches() async throws {
        let fixture = try await FixtureBuilder().build(.contentConflict, in: folder)
        var config = RepoConfig.defaults
        config.integrationBranches = [fixture.definition.targetBranch]
        config.staleDays = 3650
        try JSONEncoder().encode(config).write(to: fixture.url.appendingPathComponent(MergeDeskConstants.configFileName))
        _ = try await git.run(["config", "user.email", "fixture@example.com"], in: fixture.url)

        let result = try await DailyRunner(git: git, paths: SupportPaths(root: folder.appendingPathComponent("support")),
                                           notifier: SilentNotifier())
            .run(repositoryRoot: fixture.url, fetch: false)
        XCTAssertEqual(result.digest.fetch, .skipped)
        XCTAssertEqual(result.digest.rebaseToday, [fixture.definition.sourceBranch])
        XCTAssertEqual(result.digest.integrationConflicts.map(\.key.branch), [fixture.definition.sourceBranch])
        XCTAssertNotNil(DailyRunner.notification(for: result.digest), "something to do → notify, even on the first run")

        // The same branch once stale moves from "rebase today" to the stale list.
        config.staleDays = 1
        try JSONEncoder().encode(config).write(to: fixture.url.appendingPathComponent(MergeDeskConstants.configFileName))
        let later = try await DailyRunner(git: git, paths: SupportPaths(root: folder.appendingPathComponent("support")),
                                          notifier: SilentNotifier())
            .run(repositoryRoot: fixture.url, fetch: false)
        XCTAssertEqual(later.digest.rebaseToday, [])
        XCTAssertTrue(later.digest.stale.map(\.branch).contains(fixture.definition.sourceBranch))
    }

    func testNotificationText() {
        XCTAssertEqual(AppleScriptNotifier.quoted(#"a "b" \ c"#), #""a \"b\" \\ c""#)
    }
}

final class DailyScheduleTests: XCTestCase {
    func testTimeParsing() {
        XCTAssertEqual(DailyTime("09:30"), DailyTime(hour: 9, minute: 30))
        XCTAssertEqual(DailyTime("9:05")?.description, "09:05")
        XCTAssertNil(DailyTime("24:00"))
        XCTAssertNil(DailyTime("12:60"))
        XCTAssertNil(DailyTime("noon"))
        XCTAssertEqual(DailyTime.defaultDailyRun.description, "09:30")
    }

    /// Writes and reads the LaunchAgent without registering it with launchd.
    func testInstallReadRemoveWithoutLaunchctl() async throws {
        let folder = try TemporaryFolder.make()
        defer { try? FileManager.default.removeItem(at: folder) }
        let schedule = DailySchedule(launchAgentsFolder: folder.appendingPathComponent("LaunchAgents"),
                                     paths: SupportPaths(root: folder.appendingPathComponent("support")),
                                     usesLaunchctl: false)
        XCTAssertNil(schedule.installed())
        let time = try XCTUnwrap(DailyTime("09:30"))
        try await schedule.install(program: ["/usr/local/bin/mergedesk", "daily", "--all"], at: time)

        let installed = try XCTUnwrap(schedule.installed())
        XCTAssertEqual(installed.time, time)
        XCTAssertEqual(installed.programArguments, ["/usr/local/bin/mergedesk", "daily", "--all"])
        let plist = try XCTUnwrap(NSDictionary(contentsOf: schedule.plistURL))
        XCTAssertEqual(plist["Label"] as? String, DailySchedule.label)
        XCTAssertEqual(plist["StandardOutPath"] as? String, schedule.logURL.path)

        try await schedule.remove()
        XCTAssertNil(schedule.installed())
        try await schedule.remove()
    }
}

/// Collects notifications instead of showing them.
actor RecordingNotifier: Notifier {
    private(set) var messages: [(title: String, body: String)] = []

    func notify(title: String, body: String) async {
        messages.append((title, body))
    }
}
