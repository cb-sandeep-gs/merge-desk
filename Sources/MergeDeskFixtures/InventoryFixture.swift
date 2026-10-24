import Foundation

/// A shared repository (`origin`) and a developer's clone of it, covering every branch state the inventory
/// shows. Timeline (day 0 = 2026-01-01):
///
/// | Branch | Where | Story |
/// |---|---|---|
/// | `main` | both | day 0 |
/// | `develop` | both, in sync | day 0, then fast-forwarded to `feature/merged` |
/// | `feature/merged` | origin only | 1 commit, already in develop; stale |
/// | `feature/stale` | origin only | 1 commit off main on day 0; stale |
/// | `feature/active` | both | 2 commits on origin (day 60) + 1 unpushed local commit; touches `shared.txt` |
/// | `feature/remote-only` | origin only | 1 commit by another author (day 60); also touches `shared.txt` |
/// | `feature/local-only` | clone only | 1 commit off develop, never pushed |
public struct InventoryFixture: Sendable {
    public let origin: URL
    public let clone: URL

    public enum Branch {
        public static let main = "main"
        public static let develop = "develop"
        public static let merged = "feature/merged"
        public static let stale = "feature/stale"
        public static let active = "feature/active"
        public static let remoteOnly = "feature/remote-only"
        public static let localOnly = "feature/local-only"
    }

    /// Author of `feature/remote-only`; everything else is the default fixture author.
    public static let otherAuthor = (name: "Other Dev", email: "other@example.com")
    public static let developerEmail = "fixture@example.com"
    /// Day the recent work happens on.
    public static let recentDay = 60
    /// "Today" for staleness checks: one day after the recent work.
    public static let now = FixtureBuilder.firstCommitDate.addingTimeInterval(TimeInterval((recentDay + 1) * 86_400))

    /// Builds `<parent>/origin` and `<parent>/clone`.
    public static func build(in parent: URL, builder: FixtureBuilder = FixtureBuilder()) async throws -> InventoryFixture {
        let origin = parent.appendingPathComponent("origin", isDirectory: true)
        let clone = parent.appendingPathComponent("clone", isDirectory: true)
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        var clock = FixtureClock()

        try await builder.play([.git(["init", "--quiet", "--initial-branch=\(Branch.main)"])] + originSteps, in: origin, clock: &clock)
        try await builder.clone(origin, to: clone)
        try await builder.play(cloneSteps, in: clone, clock: &clock)
        return InventoryFixture(origin: origin, clone: clone)
    }

    private static var originSteps: [FixtureStep] {
        var steps: [FixtureStep] = [
            .write("README.md", "fixture\n"), .commit("chore: init"),
            .createBranch(Branch.develop), .write("develop.txt", "develop\n"), .commit("feat: develop work"),
            .createBranch(Branch.merged), .write("merged.txt", "merged\n"), .commit("feat: merged work"),
            .switchTo(Branch.develop), .git(["merge", "--quiet", "--ff-only", Branch.merged]),
            .switchTo(Branch.main), .createBranch(Branch.stale), .write("stale.txt", "stale\n"), .commit("feat: stale work"),
        ]
        steps += [
            .advanceDays(recentDay),
            .switchTo(Branch.develop), .createBranch(Branch.active),
            .write("active.txt", "active\n"), .write("shared.txt", "from active\n"), .commit("feat: active one"),
            .write("active2.txt", "active 2\n"), .commit("feat: active two"),
            .switchTo(Branch.develop), .createBranch(Branch.remoteOnly), .author(name: otherAuthor.name, email: otherAuthor.email),
            .write("remote.txt", "remote\n"), .write("shared.txt", "from remote-only\n"), .commit("feat: remote only"),
            .author(name: "Fixture Author", email: developerEmail),
            .switchTo(Branch.main),
        ]
        return steps
    }

    private static var cloneSteps: [FixtureStep] {
        [
            .git(["config", "user.email", developerEmail]),
            // `switch <name>` creates a local branch tracking origin/<name>.
            .switchTo(Branch.active), .write("local.txt", "local\n"), .commit("wip: unpushed"),
            .git(["switch", "--quiet", "--create", Branch.localOnly, "origin/\(Branch.develop)"]),
            .write("local-only.txt", "local only\n"), .commit("feat: local only"),
            .switchTo(Branch.develop),
            .switchTo(Branch.main),
        ]
    }
}
