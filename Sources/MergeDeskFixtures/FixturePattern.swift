import Foundation

/// Every merge situation the resolution engine must handle, as a tiny reproducible repository.
/// New resolver behaviour starts by adding a pattern here (PLAN.md §9).
public enum FixturePattern: String, CaseIterable, Sendable {
    case cleanMerge = "clean-merge"
    case contentConflict = "content-conflict"
    case identicalChange = "identical-change"
    case addAddSameSpot = "add-add-same-spot"
    case cherryPicked = "cherry-picked"
    case revertOnOneSide = "revert-on-one-side"
    case modifyDelete = "modify-delete"
    case bothAddedFile = "both-added-file"
    case generatedFile = "generated-file"
    case awkwardNames = "awkward-names"

    // Shared file contents, kept as constants so each scenario reads as "what changed".
    private enum Content {
        static let sevenLines = lines("one", "two", "three", "four", "five", "six", "seven")
        static let routeBase = lines("enum Route {", "    case home", "    case news", "}")
        static let configBase = lines("let timeout = 10", "let retries = 3", "let host = \"api\"")
    }

    private static func lines(_ items: String...) -> String { items.joined(separator: "\n") + "\n" }

    public var definition: FixtureDefinition {
        let target = FixtureBranch.target
        let source = FixtureBranch.source
        let base = FixtureBranch.base
        // Every fixture: base commit(s) on `base`, then `target` and `source` cut from it.
        func split(_ baseSteps: [FixtureStep], target targetSteps: [FixtureStep], source sourceSteps: [FixtureStep],
                   targetName: String = target, sourceName: String = source) -> [FixtureStep] {
            // Built step by step: one long `+` chain of enum literals is slow for the type checker.
            var steps = baseSteps
            steps.append(.createBranch(targetName))
            steps.append(contentsOf: targetSteps)
            steps.append(.switchTo(base))
            steps.append(.createBranch(sourceName))
            steps.append(contentsOf: sourceSteps)
            steps.append(.switchTo(targetName))
            return steps
        }

        switch self {
        case .cleanMerge:
            let file = "Notes.txt"
            return FixtureDefinition(
                pattern: self, targetBranch: target, sourceBranch: source,
                steps: split(
                    [.write(file, Content.sevenLines), .commit("chore: base notes")],
                    target: [.write(file, Content.sevenLines.replacingOccurrences(of: "seven", with: "SEVEN")), .commit("docs: last line")],
                    source: [.write(file, Content.sevenLines.replacingOccurrences(of: "one", with: "ONE")), .commit("docs: first line")]
                ),
                expectedConflicts: [],
                expectedResolution: "git merges it; both edits present"
            )

        case .contentConflict:
            let file = "Sources/App.swift"
            return FixtureDefinition(
                pattern: self, targetBranch: target, sourceBranch: source,
                steps: split(
                    [.write(file, Content.configBase), .commit("feat: config")],
                    target: [.write(file, Content.configBase.replacingOccurrences(of: "10", with: "20")), .commit("fix: longer timeout")],
                    source: [.write(file, Content.configBase.replacingOccurrences(of: "10", with: "5")), .commit("perf: shorter timeout")]
                ),
                expectedConflicts: [file],
                expectedResolution: "escalate: both sides edited the same logic"
            )

        case .identicalChange:
            let file = "Sources/App.swift"
            let edited = Content.configBase.replacingOccurrences(of: "3", with: "5")
            return FixtureDefinition(
                pattern: self, targetBranch: target, sourceBranch: source,
                steps: split(
                    [.write(file, Content.configBase), .commit("feat: config")],
                    target: [.write(file, edited), .commit("fix: more retries")],
                    source: [.write(file, edited), .commit("fix: more retries (same change)")]
                ),
                expectedConflicts: [],
                expectedResolution: "git merges it; the change appears once"
            )

        case .addAddSameSpot:
            let file = "Sources/Route.swift"
            let anchor = "    case news\n"
            return FixtureDefinition(
                pattern: self, targetBranch: target, sourceBranch: source,
                steps: split(
                    [.write(file, Content.routeBase), .commit("feat: routes")],
                    target: [.write(file, Content.routeBase.replacingOccurrences(of: anchor, with: anchor + "    case videos\n")),
                             .commit("feat(route): videos")],
                    source: [.write(file, Content.routeBase.replacingOccurrences(of: anchor, with: anchor + "    case scores\n")),
                             .commit("feat(route): scores")]
                ),
                expectedConflicts: [file],
                expectedResolution: "union: keep both `case videos` and `case scores` (additions only)"
            )

        case .cherryPicked:
            let file = "Sources/Config.swift"
            let fixed = Content.configBase.replacingOccurrences(of: "\"api\"", with: "\"api2\"")
            return FixtureDefinition(
                pattern: self, targetBranch: target, sourceBranch: source,
                steps: [.write(file, Content.configBase), .commit("feat: config"),
                        .createBranch(source), .write(file, fixed), .commit("fix: new host"),
                        .switchTo(base), .createBranch(target), .cherryPickTip(branch: source),
                        .write(file, fixed.replacingOccurrences(of: "\"api2\"", with: "\"api3\"")), .commit("fix: newer host")],
                expectedConflicts: [file],
                expectedResolution: "take target: source's change is already on target via cherry-pick (same patch-id)"
            )

        case .revertOnOneSide:
            let file = "Sources/Config.swift"
            let changed = Content.configBase.replacingOccurrences(of: "10", with: "30")
            return FixtureDefinition(
                pattern: self, targetBranch: target, sourceBranch: source,
                steps: split(
                    [.write(file, Content.configBase), .commit("feat: config"), .write(file, changed), .commit("feat: 30s timeout")],
                    target: [.write(file, changed.replacingOccurrences(of: "30", with: "45")), .commit("feat: 45s timeout")],
                    source: [.revertHead]
                ),
                expectedConflicts: [file],
                expectedResolution: "escalate with the revert highlighted: source reverts the commit target built on"
            )

        case .modifyDelete:
            let file = "Docs/Old.md"
            return FixtureDefinition(
                pattern: self, targetBranch: target, sourceBranch: source,
                steps: split(
                    [.write(file, Content.sevenLines), .commit("docs: old page")],
                    target: [.write(file, Content.sevenLines + "eight\n"), .commit("docs: extend old page")],
                    source: [.delete(file), .commit("docs: remove old page")]
                ),
                expectedConflicts: [file],
                expectedResolution: "escalate: deleted on one side, edited on the other"
            )

        case .bothAddedFile:
            let file = "Sources/New.swift"
            return FixtureDefinition(
                pattern: self, targetBranch: target, sourceBranch: source,
                steps: split(
                    [.write("README.md", "fixture\n"), .commit("chore: readme")],
                    target: [.write(file, Self.lines("struct New {}", "// target")), .commit("feat: New (target)")],
                    source: [.write(file, Self.lines("struct New {}", "// source")), .commit("feat: New (source)")]
                ),
                expectedConflicts: [file],
                expectedResolution: "escalate: both sides created the file differently"
            )

        case .generatedFile:
            let file = "Generated/Index.generated.swift"
            return FixtureDefinition(
                pattern: self, targetBranch: target, sourceBranch: source,
                steps: split(
                    [.write(file, Self.lines("// generated", "let index = \"base\"")), .commit("chore: generate")],
                    target: [.write(file, Self.lines("// generated", "let index = \"target\"")), .commit("chore: regenerate (target)")],
                    source: [.write(file, Self.lines("// generated", "let index = \"source\"")), .commit("chore: regenerate (source)")]
                ),
                expectedConflicts: [file],
                expectedResolution: "regenerate: never merge bytes; run the repo's regenerateCommand"
            )

        case .awkwardNames:
            let file = "dir with space/naïve file ü.txt"
            return FixtureDefinition(
                pattern: self, targetBranch: "feature/naïve-target", sourceBranch: "feature/ünïcode-source",
                steps: split(
                    [.write(file, Content.sevenLines), .commit("chore: awkward path")],
                    target: [.write(file, Content.sevenLines.replacingOccurrences(of: "four", with: "4")), .commit("edit (target)")],
                    source: [.write(file, Content.sevenLines.replacingOccurrences(of: "four", with: "IV")), .commit("edit (source)")],
                    targetName: "feature/naïve-target", sourceName: "feature/ünïcode-source"
                ),
                expectedConflicts: [file],
                expectedResolution: "escalate; proves paths with spaces/unicode and unicode branch names survive parsing"
            )
        }
    }
}
