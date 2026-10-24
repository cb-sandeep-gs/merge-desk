import XCTest
@testable import MergeDeskCore

final class ConfigLoaderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try TemporaryFolder.make()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func decode(_ json: String) throws -> (RepoConfig, [ConfigIssue]) {
        try ConfigLoader.decode(Data(json.utf8), path: "test.json")
    }

    private func assertInvalid(_ json: String, field: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(json), file: file, line: line) { error in
            guard case let ConfigError.invalid(_, issues) = error else {
                return XCTFail("expected .invalid, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(issues.contains { $0.field == field }, "no issue for \(field) in \(issues)", file: file, line: line)
        }
    }

    // MARK: defaults

    func testMissingFileGivesDefaults() throws {
        let loaded = try ConfigLoader.load(repositoryRoot: folder)
        XCTAssertEqual(loaded.source, .defaults)
        XCTAssertEqual(loaded.config, .defaults)
        XCTAssertEqual(loaded.warnings, [])
    }

    /// The agreed defaults (PLAN.md §0) are themselves valid and warning-free.
    func testDefaultsAreValidAndMatchThePlan() {
        XCTAssertEqual(ConfigLoader.validate(.defaults), [])
        XCTAssertEqual(RepoConfig.defaults.integrationBranches, ["develop", "main"])
        XCTAssertEqual(RepoConfig.defaults.staleDays, 21)
        XCTAssertEqual(RepoConfig.defaults.autoApplyMinConfidence.default, .high)
    }

    func testEmptyObjectFallsBackToDefaults() throws {
        let (config, warnings) = try decode("{}")
        XCTAssertEqual(config, .defaults)
        XCTAssertEqual(warnings, [])
    }

    // MARK: file

    func testFileOverridesOnlyTheKeysItSets() throws {
        let json = """
        {
          "$schema": "./docs/mergedesk.schema.json",
          "staleDays": 30,
          "fileClasses": [
            { "glob": "**/*.generated.swift", "strategy": "regenerate" },
            { "glob": "Source/release-notes/*.md", "strategy": "unionEntries" }
          ],
          "regenerateCommand": ["python3", "./mercury", "fix"],
          "autoApplyMinConfidence": { "default": "high", "byStrategy": { "unionEntries": "medium" } }
        }
        """
        try Data(json.utf8).write(to: folder.appendingPathComponent(MergeDeskConstants.configFileName))

        let loaded = try ConfigLoader.load(repositoryRoot: folder)

        XCTAssertEqual(loaded.warnings, [], "$-prefixed keys are allowed")
        XCTAssertEqual(loaded.config.staleDays, 30)
        XCTAssertEqual(loaded.config.integrationBranches, RepoConfig.defaults.integrationBranches)
        XCTAssertEqual(loaded.config.fileClass(for: "a/b/Index.generated.swift")?.strategy, .regenerate)
        XCTAssertEqual(loaded.config.fileClass(for: "Source/release-notes/App.md")?.strategy, .unionEntries)
        XCTAssertNil(loaded.config.fileClass(for: "Sources/App.swift"), "unmatched files go to the history engine")
        XCTAssertEqual(loaded.config.autoApplyMinConfidence.threshold(for: .unionEntries), .medium)
        XCTAssertEqual(loaded.config.autoApplyMinConfidence.threshold(for: .pbxproj), .high)
        XCTAssertEqual(loaded.config.autoApplyMinConfidence.threshold(for: nil), .high)
    }

    func testFirstMatchingFileClassWins() throws {
        let (config, _) = try decode("""
        { "fileClasses": [ { "glob": "**/*.json", "strategy": "escalate" }, { "glob": "a/*.json", "strategy": "jsonKeys" } ] }
        """)
        XCTAssertEqual(config.fileClass(for: "a/x.json")?.strategy, .escalate)
    }

    func testRoundTripThroughJSONKeepsEverything() throws {
        var config = RepoConfig.defaults
        config.regenerateCommand = ["make", "regen"]
        config.verifyCommands = [["make", "check"]]
        config.activeBranchPrefixes = ["feature/"]
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try decode(String(decoding: data, as: UTF8.self)).0, config)
    }

    // MARK: warnings and errors

    func testUnknownKeysAreWarningsNotErrors() throws {
        let (_, warnings) = try decode(#"{ "staleDay": 5 }"#)
        XCTAssertEqual(warnings.map(\.field), ["staleDay"])
        XCTAssertEqual(warnings.first?.severity, .warning)
    }

    func testUnprotectedIntegrationBranchIsAWarning() throws {
        let (_, warnings) = try decode(#"{ "protectedBranches": ["main"] }"#)
        XCTAssertTrue(warnings.contains { $0.field == "protectedBranches" && $0.message.contains("develop") })
    }

    func testDuplicateGlobIsAWarning() throws {
        let (_, warnings) = try decode("""
        { "fileClasses": [ { "glob": "**/*.md", "strategy": "escalate" }, { "glob": "**/*.md", "strategy": "unionEntries" } ] }
        """)
        XCTAssertTrue(warnings.contains { $0.field == "fileClasses[1].glob" })
    }

    func testSemanticErrors() {
        assertInvalid(#"{ "schemaVersion": 2 }"#, field: "schemaVersion")
        assertInvalid(#"{ "schemaVersion": 0 }"#, field: "schemaVersion")
        assertInvalid(#"{ "integrationBranches": [] }"#, field: "integrationBranches")
        assertInvalid(#"{ "integrationBranches": ["main", "main"] }"#, field: "integrationBranches")
        assertInvalid(#"{ "integrationBranches": ["main", " "] }"#, field: "integrationBranches[1]")
        assertInvalid(#"{ "staleDays": 0 }"#, field: "staleDays")
        assertInvalid(#"{ "staleDays": 99999 }"#, field: "staleDays")
        assertInvalid(#"{ "activeBranchPrefixes": [""] }"#, field: "activeBranchPrefixes[0]")
        assertInvalid(#"{ "fileClasses": [ { "glob": "**/*.g.swift", "strategy": "regenerate" } ] }"#, field: "regenerateCommand")
        assertInvalid(#"{ "regenerateCommand": [] }"#, field: "regenerateCommand")
        assertInvalid(#"{ "verifyCommands": [[]] }"#, field: "verifyCommands[0]")
    }

    func testMalformedFilesNameTheField() {
        let cases: [(String, String)] = [
            (#"{ "staleDays": "three" }"#, "staleDays"),
            (#"{ "fileClasses": [ { "glob": "*.md", "strategy": "magic" } ] }"#, "fileClasses[0].strategy"),
            (#"{ "fileClasses": [ { "glob": "a/**b", "strategy": "escalate" } ] }"#, "fileClasses[0].glob"),
            (#"{ "autoApplyMinConfidence": { "byStrategy": { "nope": "high" } } }"#, "autoApplyMinConfidence.byStrategy"),
            (#"{ "staleDays": 3 "#, "(root)"),
        ]
        for (json, field) in cases {
            XCTAssertThrowsError(try decode(json), json) { error in
                guard case let ConfigError.malformed(_, reason) = error else { return XCTFail("expected .malformed for \(json)") }
                XCTAssertTrue(reason.hasPrefix(field), "'\(reason)' should start with \(field)")
            }
        }
    }

    // MARK: queries

    func testBranchQueries() throws {
        var config = RepoConfig.defaults
        XCTAssertTrue(config.isProtected(branch: "main"))
        XCTAssertTrue(config.isProtected(branch: "release/26.10"))
        XCTAssertFalse(config.isProtected(branch: "feature/x"))

        XCTAssertFalse(config.isActiveWork(branch: "develop"))
        XCTAssertTrue(config.isActiveWork(branch: "spike/x"), "no prefixes = every non-integration branch")
        config.activeBranchPrefixes = ["feature/"]
        XCTAssertTrue(config.isActiveWork(branch: "feature/x"))
        XCTAssertFalse(config.isActiveWork(branch: "spike/x"))

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 24 * 60 * 60
        XCTAssertFalse(config.isStale(lastCommit: now.addingTimeInterval(-21 * day), now: now), "exactly 21 days is not yet stale")
        XCTAssertTrue(config.isStale(lastCommit: now.addingTimeInterval(-21 * day - 1), now: now))
    }

    func testConfidenceOrdering() {
        XCTAssertLessThan(Confidence.low, .medium)
        XCTAssertLessThan(Confidence.medium, .high)
    }
}
