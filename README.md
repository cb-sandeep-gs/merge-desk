# Merge Desk

A macOS app and CLI for any Cricbuzz git repository. It lists every branch with its health, predicts conflicts
before anyone merges, runs merges safely, and resolves conflicts from file-type rules and **git history** — with
evidence and a confidence score for every decision.

> **Status: MD-0 (foundations).** The core library, configuration, audit log, fixture repositories and a minimal
> CLI exist. The app, dashboard and resolvers arrive in MD-1 → MD-8 — see [docs/PLAN.md](docs/PLAN.md).

## Requirements

- macOS 14+, Xcode 16+ (Swift 6 toolchain)
- git 2.38+ (`git merge-tree --write-tree`); `mergedesk doctor` checks this

## Build, test, run

```bash
swift build
swift test
swift run mergedesk --help
```

| Command | What it does |
|---|---|
| `mergedesk version` | Merge Desk and git versions |
| `mergedesk doctor [--repo PATH]` | Checks git, the repository, its `.mergedesk.json` and that the integration branches exist |
| `mergedesk config validate [--repo PATH \| --file PATH]` | Validates a config; exits 1 on errors, prints warnings |
| `mergedesk config show [--repo PATH]` | The configuration in force (file merged with defaults) |
| `mergedesk config init [--repo PATH] [--force]` | Writes a `.mergedesk.json` with the defaults |
| `mergedesk fixtures list` | The conflict patterns and what each expects |
| `mergedesk fixtures build DIR [--pattern NAME]` | Builds the fixture repositories to inspect by hand |

## Layout

```
Sources/
  MergeDeskCore/        all logic, no UI
    Git/                GitClient (the only code that runs git), GitQuery (command + parser pairs), parsers, models
    Config/             RepoConfig (.mergedesk.json), ConfigLoader (decode + validate), GlobPattern
    Storage/            AuditLog (append-only JSONL), SupportPaths (~/Library/Application Support/MergeDesk)
  MergeDeskFixtures/    scripted, deterministic git repositories, one per conflict pattern
  mergedesk/            CLI (swift-argument-parser)
Tests/MergeDeskCoreTests/
docs/
  PLAN.md               product plan, decisions and phases
  mergedesk.schema.json JSON schema for editors
  examples/             example configs (Mercury iOS)
```

## Per-repository configuration

Commit a `.mergedesk.json` at the repository root (`mergedesk config init` writes one). Every key is optional;
see [docs/mergedesk.schema.json](docs/mergedesk.schema.json) and the
[Mercury iOS example](docs/examples/mercury-ios.mergedesk.json).

| Key | Default | Meaning |
|---|---|---|
| `integrationBranches` | `["develop", "main"]` | Branches everything is compared and predicted against |
| `protectedBranches` | `["main", "develop", "release/*"]` | Only changed through a pull request |
| `staleDays` | `21` | Days without commits before a branch is stale |
| `activeBranchPrefixes` | `[]` (all) | Branches in the branch × branch conflict matrix |
| `fileClasses` | pbxproj → `pbxproj`, Package.resolved → `escalate` | First matching glob picks the Tier-1 strategy |
| `regenerateCommand` | none | Run after `regenerate` files are taken; required if any rule uses it |
| `verifyCommands` | `[]` | Run before a merge is marked ready |
| `autoApplyMinConfidence` | `{ "default": "high" }` | Below this, a person decides |

## Safety principles

Merge Desk never works in your checkout (merges run in their own worktree), saves a backup ref before every merge,
never pushes or deletes without an explicit confirm, sends protected branches through a PR, and sends nothing off
the machine except `git fetch/push` and the optional `gh` CLI.

## Fixture repositories

Every resolver behaviour starts as a fixture in `Sources/MergeDeskFixtures/FixturePattern.swift`: a tiny repository
built with real git, isolated from your git config, with fixed dates, so commit ids are identical on every machine.
The tests check that git reports exactly the conflicts each fixture declares; later phases check each resolver's
output against the fixture's expected resolution.
