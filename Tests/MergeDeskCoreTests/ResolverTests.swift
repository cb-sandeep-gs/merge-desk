import XCTest
@testable import MergeDeskCore
@testable import MergeDeskFixtures

/// Pure algorithms behind the Tier-1 resolvers.
final class LineMergeTests: XCTestCase {
    private func merged(_ base: [String], _ ours: [String], _ theirs: [String]) -> [String]? {
        if case let .merged(lines, _) = LineMerge.merge(base: base, ours: ours, theirs: theirs) { return lines }
        return nil
    }

    func testBothSidesInsertAtTheSameSpotKeepsOursThenTheirs() {
        let result = LineMerge.merge(base: ["a", "z"], ours: ["a", "b", "z"], theirs: ["a", "c", "z"])
        XCTAssertEqual(result, .merged(["a", "b", "c", "z"], pureInsertion: true))
    }

    func testIdenticalInsertionIsKeptOnce() {
        XCTAssertEqual(merged(["a"], ["a", "x", "b"], ["a", "x", "c"]), ["a", "x", "b", "c"])
    }

    func testOneSideDeletesTheOtherInserts() {
        let result = LineMerge.merge(base: ["a", "old", "z"], ours: ["a", "z"], theirs: ["a", "old", "new", "z"])
        XCTAssertEqual(result, .merged(["a", "new", "z"], pureInsertion: false))
    }

    func testBothChangingTheSameLineDifferentlyIsAConflict() {
        guard case let .conflict(reason) = LineMerge.merge(base: ["v = 1;"], ours: ["v = 2;"], theirs: ["v = 3;"]) else {
            return XCTFail("expected a conflict")
        }
        XCTAssertTrue(reason.contains("v = 1;"))
    }

    func testBothMakingTheSameChangeMerges() {
        XCTAssertEqual(merged(["a", "v = 1;"], ["a", "v = 2;", "b"], ["a", "v = 2;", "c"]), ["a", "v = 2;", "b", "c"])
    }

    func testDeleteVersusChangeIsAConflict() {
        guard case let .conflict(reason) = LineMerge.merge(base: ["a", "v = 1;"], ours: ["a"], theirs: ["a", "v = 2;"]) else {
            return XCTFail("expected a conflict")
        }
        XCTAssertTrue(reason.contains("deleted"))
    }

    func testConflictingAssignments() {
        XCTAssertEqual(LineMerge.conflictingAssignments(["\tVERSION = 2;", "\tVERSION = 3;", "\tNAME = x;"]), ["VERSION"])
        XCTAssertEqual(LineMerge.conflictingAssignments(["A1 /* a */ = {isa = X;};", "A1 /* a */ = {isa = X;};"]), [],
                       "the same line twice isn't a clash")
        XCTAssertEqual(LineMerge.conflictingAssignments(["A1 /* a.swift */ = {isa = X;};", "A1 /* b.swift */ = {isa = Y;};"]), ["A1"])
    }

    func testConflictedTextParsesBlocksAndResolves() {
        let marker = { (character: Character) in String(repeating: character, count: ConflictedText.markerSize) }
        let output = ["top", marker("<") + " ours", "b", marker("|") + " base", marker("="), "c", marker(">") + " theirs", "end"]
            .joined(separator: "\n") + "\n"
        let text = ConflictedText(mergeFileOutput: output)
        XCTAssertEqual(text.conflictCount, 1)
        XCTAssertEqual(text.segments[1], .conflict(ours: ["b"], base: [], theirs: ["c"]))
        let resolved = text.resolved { LineMerge.merge(base: $1, ours: $0, theirs: $2) }
        XCTAssertEqual(resolved?.text, "top\nb\nc\nend\n")
    }

    func testTextLinesRoundTrip() {
        for text in ["", "a", "a\n", "a\nb", "a\nb\n", "\n"] {
            XCTAssertEqual(TextLines(text).text, text, text.debugDescription)
        }
    }
}

final class OrderedJSONTests: XCTestCase {
    private let xcodeStyle = """
    {
      "images" : [
        {
          "idiom" : "universal",
          "scale" : "1x"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """

    func testRoundTripKeepsXcodeLayoutExactly() throws {
        let json = try OrderedJSON(parsing: Data(xcodeStyle.utf8))
        XCTAssertEqual(json.serialized(JSONStyle.detect(xcodeStyle)), xcodeStyle)
    }

    func testMergeKeepsBothSidesKeysInOrder() throws {
        let base = try OrderedJSON(parsing: Data(#"{"a": 1, "b": 2}"#.utf8))
        let ours = try OrderedJSON(parsing: Data(#"{"a": 1, "b": 2, "c": 3}"#.utf8))
        let theirs = try OrderedJSON(parsing: Data(#"{"d": 4, "a": 1, "b": 2}"#.utf8))
        let merged = try OrderedJSON.merge(base: base, ours: ours, theirs: theirs)
        XCTAssertEqual(merged?.serialized(.standard), "{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3,\n  \"d\": 4\n}\n")
    }

    func testSameKeyChangedDifferentlyIsAConflict() throws {
        let base = try OrderedJSON(parsing: Data(#"{"x": {"y": 1}}"#.utf8))
        let ours = try OrderedJSON(parsing: Data(#"{"x": {"y": 2}}"#.utf8))
        let theirs = try OrderedJSON(parsing: Data(#"{"x": {"y": 3}}"#.utf8))
        XCTAssertThrowsError(try OrderedJSON.merge(base: base, ours: ours, theirs: theirs)) {
            XCTAssertEqual($0 as? JSONMergeConflict, JSONMergeConflict(path: "$.x.y"))
        }
    }

    /// A key deleted on one side and changed on the other must not silently disappear.
    func testDeleteVersusChangeIsAConflict() throws {
        let base = try OrderedJSON(parsing: Data(#"{"k": 1, "z": 0}"#.utf8))
        let ours = try OrderedJSON(parsing: Data(#"{"z": 0}"#.utf8))
        let theirs = try OrderedJSON(parsing: Data(#"{"k": 2, "z": 0}"#.utf8))
        XCTAssertThrowsError(try OrderedJSON.merge(base: base, ours: ours, theirs: theirs))
        let unchanged = try OrderedJSON(parsing: Data(#"{"k": 1, "z": 0}"#.utf8))
        XCTAssertEqual(try OrderedJSON.merge(base: base, ours: ours, theirs: unchanged), ours, "delete vs untouched = deleted")
    }

    func testEquivalenceIgnoresKeyOrderAndNumberSpelling() throws {
        let one = try OrderedJSON(parsing: Data(#"{"a": 1.0, "b": [true, null, "sé"]}"#.utf8))
        let two = try OrderedJSON(parsing: Data(#"{"b": [true, null, "sé"], "a": 1}"#.utf8))
        XCTAssertTrue(one.isEquivalent(to: two))
        XCTAssertNotEqual(one, two, "order still matters for ==")
        XCTAssertThrowsError(try OrderedJSON(parsing: Data(#"{"a": }"#.utf8)))
    }
}

/// Every strategy through a real merge session.
final class AutoResolveSessionTests: XCTestCase {
    private var folder: URL!
    private let git = ProcessGitClient(environmentOverrides: FixtureBuilder.isolatedEnvironment)

    override func setUpWithError() throws { folder = try TemporaryFolder.make() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func config(regenerate: [String]? = nil) -> RepoConfig {
        var config = RepoConfig.defaults
        config.integrationBranches = [FixtureBranch.target]
        config.protectedBranches = []
        config.fileClasses = [
            FileClassRule(glob: GlobPattern(staticPattern: "**/*.pbxproj"), strategy: .pbxproj),
            FileClassRule(glob: GlobPattern(staticPattern: "release-notes/*.md"), strategy: .unionEntries),
            FileClassRule(glob: GlobPattern(staticPattern: "Config/*.json"), strategy: .jsonKeys),
            FileClassRule(glob: GlobPattern(staticPattern: "**/*.generated.swift"), strategy: .regenerate, command: regenerate),
        ]
        config.regenerateCommand = ["false"]
        return config
    }

    private func run(_ pattern: FixturePattern, regenerate: [String]? = nil) async throws -> (MergeSession, URL) {
        let fixture = try await FixtureBuilder().build(pattern, in: folder)
        let manager = SessionManager(repositoryRoot: fixture.url, config: config(regenerate: regenerate), git: git,
                                     paths: SupportPaths(root: folder.appendingPathComponent("support")),
                                     github: GitHubCLI(executableURL: nil))
        let planned = try await manager.plan(source: FixtureBranch.source, target: FixtureBranch.target)
        return (try await manager.start(planned.id, fetch: false), fixture.url)
    }

    private func content(_ session: MergeSession, _ path: String, in root: URL) async throws -> String {
        let result = try await git.run(["show", "\(try XCTUnwrap(session.resultID)):\(path)"], in: root)
        return String(decoding: result.standardOutput, as: UTF8.self)
    }

    func testPBXProjAdditionsMergeAndValidate() async throws {
        let (session, root) = try await run(.pbxprojAddAdd)
        XCTAssertEqual(session.state, .ready, session.resolutions?.first?.note ?? "")
        XCTAssertEqual(session.resolutions?.map(\.status), [.applied])
        XCTAssertEqual(session.resolutions?.first?.tier, .fileRule(.pbxproj))
        let merged = try await content(session, TierOneFixtures.projectPath, in: root)
        XCTAssertEqual(merged, XcodeProjectText.make(files: [.app, .target, .source]), "both files in every section, ours first")
        let problem = await PBXProjValidator.problem(in: Data(merged.utf8), comparedWith: Data())
        XCTAssertNil(problem)
    }

    func testPBXProjSameSettingEscalates() async throws {
        let (session, _) = try await run(.pbxprojSameSetting)
        XCTAssertEqual(session.state, .resolving)
        XCTAssertEqual(session.resolutions?.first?.status, .escalated)
        XCTAssertTrue(session.resolutions?.first?.note.contains("CURRENT_PROJECT_VERSION") ?? false, session.resolutions?.first?.note ?? "")
        XCTAssertEqual(session.conflictedFiles, [TierOneFixtures.projectPath])
    }

    func testReleaseNotesKeepBothEntries() async throws {
        let (session, root) = try await run(.releaseNotesUnion)
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(session.resolutions?.first?.confidence, .high)
        let merged = try await content(session, TierOneFixtures.releaseNotesPath, in: root)
        XCTAssertEqual(merged, "# Release notes\n\n- 1.1: scores widget\n- 1.1: videos tab\n- 1.0: first release\n")
    }

    func testJSONKeysMergeAndSameKeyEscalates() async throws {
        let (session, root) = try await run(.jsonKeys)
        XCTAssertEqual(session.state, .ready)
        let merged = try await content(session, TierOneFixtures.jsonPath, in: root)
        XCTAssertEqual(merged, TierOneFixtures.json(["home", "scores", "videos"]), "layout and key order kept")

        let (clash, _) = try await run(.jsonSameKey)
        XCTAssertEqual(clash.state, .resolving)
        XCTAssertEqual(clash.resolutions?.first?.note, "both sides changed $.flags.home")
    }

    func testRegenerateRunsTheGeneratorAndCommitsItsOutput() async throws {
        let generator = ["/bin/sh", "-c", "printf '// generated\\nlet index = \"merged\"\\n' > Generated/Index.generated.swift"]
        let (session, root) = try await run(.generatedFile, regenerate: generator)
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(session.resolutions?.first?.status, .applied)
        let merged = try await content(session, "Generated/Index.generated.swift", in: root)
        XCTAssertEqual(merged, "// generated\nlet index = \"merged\"\n")
    }

    func testFailedGeneratorPutsTheConflictBack() async throws {
        let (session, _) = try await run(.generatedFile, regenerate: ["false"])
        XCTAssertEqual(session.state, .resolving)
        XCTAssertEqual(session.resolutions?.first?.status, .needsRegeneration)
        let worktree = URL(fileURLWithPath: try XCTUnwrap(session.worktreePath))
        XCTAssertTrue(SessionManager.hasConflictMarkers(worktree.appendingPathComponent("Generated/Index.generated.swift")),
                      "the markers are back for a person")
    }

    func testUnclassifiedFilesAreLeftForAPerson() async throws {
        let (session, _) = try await run(.contentConflict)
        XCTAssertEqual(session.state, .resolving)
        XCTAssertEqual(session.resolutions?.first?.tier, .unhandled)
    }

    /// Tier 2: a resolution recorded in one session is replayed in the next.
    func testRerereReplaysARecordedResolution() async throws {
        let fixture = try await FixtureBuilder().build(.contentConflict, in: folder)
        let manager = SessionManager(repositoryRoot: fixture.url, config: config(), git: git,
                                     paths: SupportPaths(root: folder.appendingPathComponent("support")),
                                     github: GitHubCLI(executableURL: nil))
        var first = try await manager.plan(source: FixtureBranch.source, target: FixtureBranch.target)
        first = try await manager.start(first.id, fetch: false)
        let worktree = URL(fileURLWithPath: try XCTUnwrap(first.worktreePath))
        let resolved = "let timeout = 15\nlet retries = 3\nlet host = \"api\"\n"
        try Data(resolved.utf8).write(to: worktree.appendingPathComponent("Sources/App.swift"))
        first = try await manager.continueAfterResolving(first.id)
        XCTAssertEqual(first.state, .ready)
        _ = try await manager.abort(first.id)

        var second = try await manager.plan(source: FixtureBranch.source, target: FixtureBranch.target)
        second = try await manager.start(second.id, fetch: false)
        XCTAssertEqual(second.state, .ready, "the recorded resolution was reused")
        XCTAssertEqual(second.resolutions?.first?.tier, .rerere)
        let merged = try await git.run(["show", "\(try XCTUnwrap(second.resultID)):Sources/App.swift"], in: fixture.url)
        XCTAssertEqual(String(decoding: merged.standardOutput, as: UTF8.self), resolved)
    }

    func testRerereMessageParsing() {
        let output = "Auto-merging a\nResolved 'Sources/App.swift' using previous resolution.\nCONFLICT (content): b\n"
        XCTAssertEqual(AutoResolver.rerereResolvedPaths(output), ["Sources/App.swift"])
    }
}

/// The replay benchmark scores against what was really committed.
final class ReplayBenchmarkTests: XCTestCase {
    private var folder: URL!
    private let git = ProcessGitClient(environmentOverrides: FixtureBuilder.isolatedEnvironment)

    override func setUpWithError() throws { folder = try TemporaryFolder.make() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// Builds `pattern`, merges source into target, and commits `committed` as the person's resolution of `path`.
    private func history(_ pattern: FixturePattern, path: String, committed: String) async throws -> URL {
        let fixture = try await FixtureBuilder().build(pattern, in: folder)
        _ = try await git.run(["merge", "--no-ff", "--no-commit", FixtureBranch.source], in: fixture.url)
        try Data(committed.utf8).write(to: fixture.url.appendingPathComponent(path))
        _ = try await git.run(["add", "--all"], in: fixture.url)
        let commit = try await git.run(["commit", "--quiet", "-m", "Merge source"], in: fixture.url)
        XCTAssertEqual(commit.exitCode, 0, commit.errorText)
        return fixture.url
    }

    private func config(_ glob: String, _ strategy: FileStrategy) -> RepoConfig {
        var config = RepoConfig.defaults
        config.fileClasses = [FileClassRule(glob: GlobPattern(staticPattern: glob), strategy: strategy)]
        return config
    }

    func testMatchingResolutionScoresExact() async throws {
        let root = try await history(.pbxprojAddAdd, path: TierOneFixtures.projectPath,
                                     committed: XcodeProjectText.make(files: [.app, .target, .source]))
        let benchmark = ReplayBenchmark(git: git, paths: SupportPaths(root: folder.appendingPathComponent("support")))
        let report = try await benchmark.run(repositoryRoot: root, config: config("**/*.pbxproj", .pbxproj), since: "50.years")
        XCTAssertEqual(report.mergesExamined, 1)
        XCTAssertEqual(report.mergesWithConflicts, 1)
        XCTAssertEqual(report.cases.map(\.verdict), [.exact])
        XCTAssertTrue(report.meetsGate)
        let status = try await git.execute(.status, in: root)
        XCTAssertTrue(status.isClean, "the repository itself is never touched")
    }

    func testDifferentResolutionScoresWrongAndFailsTheGate() async throws {
        // The person kept only theirs; a union is then "wrong" — exactly how Mercury's release notes were caught.
        let theirs = "# Release notes\n\n- 1.1: videos tab\n- 1.0: first release\n"
        let root = try await history(.releaseNotesUnion, path: TierOneFixtures.releaseNotesPath, committed: theirs)
        let benchmark = ReplayBenchmark(git: git, paths: SupportPaths(root: folder.appendingPathComponent("support")))
        let report = try await benchmark.run(repositoryRoot: root, config: config("release-notes/*.md", .unionEntries), since: "50.years")
        XCTAssertEqual(report.cases.map(\.verdict), [.wrong])
        XCTAssertFalse(report.meetsGate)
        XCTAssertTrue(report.cases.first?.note.contains("line 3") ?? false, report.cases.first?.note ?? "")
        let summary = try XCTUnwrap(report.summaries.first)
        XCTAssertEqual(summary.accuracy, 0)
    }

    func testEquivalenceForJSONAndProjects() async {
        let left = Data(#"{"a": 1, "b": 2}"#.utf8)
        let right = Data("{\n  \"b\" : 2,\n  \"a\" : 1\n}\n".utf8)
        let jsonEquivalent = await ReplayBenchmark.isEquivalent(left, right, path: "x.json")
        XCTAssertTrue(jsonEquivalent)
        let markdownEquivalent = await ReplayBenchmark.isEquivalent(left, right, path: "x.md")
        XCTAssertFalse(markdownEquivalent, "only JSON and pbxproj have a looser comparison")
    }
}

/// Resolving by hand, file by file.
final class ManualResolutionTests: XCTestCase {
    private var folder: URL!
    private let git = ProcessGitClient(environmentOverrides: FixtureBuilder.isolatedEnvironment)

    override func setUpWithError() throws { folder = try TemporaryFolder.make() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private struct Started {
        let manager: SessionManager
        let session: MergeSession
        let root: URL
    }

    private func start(_ pattern: FixturePattern) async throws -> Started {
        let fixture = try await FixtureBuilder().build(pattern, in: folder)
        var config = RepoConfig.defaults
        config.protectedBranches = []
        let manager = SessionManager(repositoryRoot: fixture.url, config: config, git: git,
                                     paths: SupportPaths(root: folder.appendingPathComponent("support")),
                                     github: GitHubCLI(executableURL: nil))
        let planned = try await manager.plan(source: FixtureBranch.source, target: FixtureBranch.target)
        return Started(manager: manager, session: try await manager.start(planned.id, fetch: false), root: fixture.url)
    }

    func testRenderChoices() {
        let marker = { (character: Character) in String(repeating: character, count: ConflictedText.markerSize) }
        let text = ConflictedText(mergeFileOutput: ["a", "b", marker("<") + " ours", "X", marker("|") + " base", "o", marker("="), "Y",
                                                    marker(">") + " theirs", "c"].joined(separator: "\n") + "\n")
        XCTAssertEqual(text.blocks.first?.before, ["a", "b"])
        XCTAssertEqual(text.blocks.first?.after, ["c"])
        XCTAssertEqual(text.render(choices: [.into]), "a\nb\nX\nc\n")
        XCTAssertEqual(text.render(choices: [.from]), "a\nb\nY\nc\n")
        XCTAssertEqual(text.render(choices: [.both]), "a\nb\nX\nY\nc\n")
        XCTAssertNil(text.render(choices: []), "every block needs a choice")
    }

    func testResolveATextConflictByChoosingBlocks() async throws {
        let run = try await start(.contentConflict)
        let (manager, started, root) = (run.manager, run.session, run.root)
        guard case let .text(text) = try await manager.fileConflict(started.id, path: "Sources/App.swift") else {
            return XCTFail("expected a text conflict")
        }
        XCTAssertEqual(text.conflictCount, 1)
        XCTAssertEqual(text.blocks.first?.into, ["let timeout = 20"])
        XCTAssertEqual(text.blocks.first?.from, ["let timeout = 5"])

        do {
            _ = try await manager.resolveFile(started.id, path: "Sources/App.swift", content: Data("<<<<<<< x\n".utf8))
            XCTFail("markers are refused")
        } catch SessionError.unresolved {}

        let content = try XCTUnwrap(text.render(choices: [.from]))
        var session = try await manager.resolveFile(started.id, path: "Sources/App.swift", content: Data(content.utf8))
        XCTAssertEqual(session.conflictedFiles, [])
        XCTAssertEqual(session.resolutions?.first { $0.path == "Sources/App.swift" }?.tier, .manual)
        session = try await manager.continueAfterResolving(session.id)
        XCTAssertEqual(session.state, .ready)
        let merged = try await git.run(["show", "\(try XCTUnwrap(session.resultID)):Sources/App.swift"], in: root)
        XCTAssertEqual(String(decoding: merged.standardOutput, as: UTF8.self), content)
    }

    func testDeletedOnOneSideOffersKeepOrDelete() async throws {
        let run = try await start(.modifyDelete)
        let (manager, started, root) = (run.manager, run.session, run.root)
        let conflict = try await manager.fileConflict(started.id, path: "Docs/Old.md")
        XCTAssertEqual(conflict, .presentOnOneSide(inInto: true, inFrom: false))
        // Take source's side: the file is deleted.
        var session = try await manager.useVersion(started.id, path: "Docs/Old.md", side: .from)
        session = try await manager.continueAfterResolving(session.id)
        XCTAssertEqual(session.state, .ready)
        let shown = try await git.run(["show", "\(try XCTUnwrap(session.resultID)):Docs/Old.md"], in: root)
        XCTAssertNotEqual(shown.exitCode, 0, "the file is gone in the merge")
    }

    func testBinaryDetection() {
        XCTAssertTrue(SessionManager.isBinary(Data([0x89, 0x50, 0x00, 0x47])))
        XCTAssertFalse(SessionManager.isBinary(Data("plain text\n".utf8)))
    }
}
